defmodule Kodo.Agent.Loop do
  @moduledoc "Event-driven, restartable primary-agent model and runner loop."

  alias Kodo.Agent.ModelMapping
  alias Kodo.Agent.ReviewResult
  alias Kodo.Agent.Roles
  alias Kodo.Agent.Tools
  alias Kodo.LLM
  alias Kodo.RunnerProtocol
  alias Kodo.Runners
  alias Kodo.Sessions
  alias Kodo.Sessions.Projection

  @protocol_version RunnerProtocol.version()

  def run(session_id, opts \\ []) do
    budgets = Keyword.get(opts, :budgets, Application.fetch_env!(:kodo, :agent_budgets))
    adapter = Keyword.get(opts, :adapter, LLM.adapter())
    ownership = Keyword.fetch!(opts, :ownership)
    resume(session_id, adapter, budgets, ownership)
  end

  defp resume(session_id, adapter, budgets, ownership) do
    events = Sessions.events_after(session_id)
    projection = Projection.from_events(events)
    turn_events = current_turn(events)
    responses = Enum.filter(turn_events, &(&1.type == "model_response"))
    invocations = Enum.count(turn_events, &(&1.type == "model_invocation_started"))
    tokens = usage(turn_events)

    latest_invocation =
      List.last(Enum.filter(turn_events, &(&1.type == "model_invocation_started")))

    latest_response = List.last(responses)

    case rehoming_boundary() do
      :ok ->
        case within_budget(invocations, tokens, budgets) do
          :ok ->
            action = next_action(latest_invocation, latest_response)

            resume_action(
              action,
              session_id,
              projection,
              events,
              adapter,
              budgets,
              invocations,
              ownership
            )

          error ->
            error
        end

      error ->
        error
    end
  end

  defp resume_action(
         :infer,
         session_id,
         projection,
         events,
         adapter,
         budgets,
         invocations,
         ownership
       ) do
    infer(session_id, projection, events, adapter, budgets, invocations + 1, ownership)
  end

  defp resume_action(
         %{payload: %{"tool_calls" => calls}} = response,
         session_id,
         projection,
         _events,
         adapter,
         budgets,
         invocations,
         ownership
       )
       when calls != [] do
    case execute_tools(
           session_id,
           projection.runner_id,
           response,
           calls,
           adapter,
           projection.model_mapping || legacy_mapping(projection.model),
           budgets,
           ownership
         ) do
      {:ok, _results} ->
        continue_after_tools(session_id, adapter, budgets, invocations, ownership)

      error ->
        error
    end
  end

  defp resume_action(
         %{payload: %{"tool_calls" => [], "text" => text}} = response,
         session_id,
         projection,
         events,
         adapter,
         budgets,
         invocations,
         ownership
       ) do
    context = %{
      session_id: session_id,
      projection: projection,
      events: events,
      adapter: adapter,
      budgets: budgets,
      invocations: invocations,
      ownership: ownership
    }

    review_final_answer(text, response, context)
  end

  defp review_final_answer(text, response, context) do
    mapping =
      context.projection.model_mapping || legacy_mapping(context.projection.model)

    primary_invocation_id = response.payload["invocation_id"]

    case review_result(context.events, primary_invocation_id) do
      nil ->
        run_final_review(text, primary_invocation_id, Map.put(context, :mapping, mapping))

      result ->
        handle_review_result(
          text,
          result,
          context.session_id,
          context.adapter,
          context.budgets,
          context.invocations,
          context.ownership
        )
    end
  end

  defp review_result(events, primary_invocation_id) do
    events
    |> Enum.filter(fn event ->
      event.type == "review_result" and
        event.payload["primary_invocation_id"] == primary_invocation_id
    end)
    |> List.last()
  end

  defp original_task(events) do
    events
    |> Enum.filter(&(&1.type == "user_message"))
    |> List.last()
    |> then(& &1.payload["content"])
  end

  defp run_final_review(text, primary_invocation_id, context) do
    review = ModelMapping.role!(context.mapping, :review)
    contract = Roles.fetch!(:review, review["role_contract"])

    with {:ok, capability_validation} <-
           context.adapter.validate_model(review["model"], review, contract),
         {:ok, request} <- resolve_request(context.session_id, review),
         :ok <-
           Phoenix.PubSub.subscribe(
             Kodo.PubSub,
             "runner_responses:#{context.projection.runner_id}"
           ),
         :ok <- Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{context.session_id}"),
         :ok <- Runners.subscribe_lifecycle(),
         {:ok, review_invocation_id} <-
           start_review_invocation(
             context.session_id,
             primary_invocation_id,
             context.mapping,
             review,
             contract,
             capability_validation,
             context.ownership
           ),
         {:ok, diff} <-
           execute_tool(
             context.session_id,
             context.projection.runner_id,
             review_invocation_id,
             %{"id" => "final-diff", "name" => "git_diff", "arguments" => %{"paths" => []}},
             Sessions.events_after(context.session_id),
             context.budgets[:tool_timeout],
             context.ownership
           ),
         :ok <- rehoming_boundary(),
         {:ok, generated} <-
           Sessions.dispatch_if_owner(context.ownership, fn ->
             task = original_task(context.events)

             generate_object(
               context.adapter,
               request,
               [
                 %{"role" => "system", "content" => contract.prompt},
                 %{
                   "role" => "user",
                   "content" =>
                     "Original task:\n#{task}\n\nReview this final diff:\n\n#{diff.output["content"]}"
                 }
               ],
               ReviewResult.schema(),
               timeout: context.budgets[:model_timeout],
               reasoning: review["reasoning"]
             )
           end),
         :ok <- within_budget(1, token_count(generated.usage), contract.budget),
         {:ok, result} <- validate_review_object(generated.object),
         result = ReviewResult.actionable(result, diff.output["content"]),
         {:ok, result_event} <-
           persist_review_result(
             context.session_id,
             primary_invocation_id,
             review_invocation_id,
             generated.usage,
             result,
             context.ownership
           ) do
      handle_review_result(
        text,
        result_event,
        context.session_id,
        context.adapter,
        context.budgets,
        context.invocations,
        context.ownership
      )
    end
  end

  defp start_review_invocation(
         session_id,
         primary_invocation_id,
         mapping,
         review,
         contract,
         capability_validation,
         ownership
       ) do
    invocation_id = Ecto.UUID.generate()

    case Sessions.append_event(
           session_id,
           "review_invocation_started",
           %{
             "invocation_id" => invocation_id,
             "primary_invocation_id" => primary_invocation_id,
             "role" => "review",
             "provider" => review["provider"],
             "model" => review["model"],
             "reasoning" => review["reasoning"],
             "role_contract" => contract.id,
             "toolset_version" => contract.toolset_version,
             "capability_validation" => capability_validation,
             "model_mapping" => mapping
           },
           version: 1,
           parent_id: primary_invocation_id,
           ownership: ownership
         ) do
      {:ok, _event} -> {:ok, invocation_id}
      error -> error
    end
  end

  defp validate_review_object(object) do
    with {:ok, encoded} <- Jason.encode(object),
         {:ok, normalized} <- Jason.decode(encoded),
         true <- Enum.sort(Map.keys(normalized)) == ["clean", "findings"],
         clean when is_boolean(clean) <- normalized["clean"],
         findings when is_list(findings) <- normalized["findings"],
         true <- Enum.all?(findings, &valid_review_finding?/1),
         true <- (clean and findings == []) or (not clean and findings != []) do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_review_result}
    end
  end

  defp valid_review_finding?(finding) do
    expected_keys = ["explanation", "line", "path", "severity", "suggested_fix"]

    Enum.sort(Map.keys(finding)) == expected_keys and
      Enum.all?(finding, &valid_review_field?/1)
  end

  defp valid_review_field?({"severity", severity}),
    do: severity in ["low", "medium", "high"]

  defp valid_review_field?({"line", line}), do: is_integer(line) and line > 0

  defp valid_review_field?({field, value})
       when field in ["path", "explanation", "suggested_fix"],
       do: is_binary(value) and value != ""

  defp valid_review_field?(_field), do: false

  defp persist_review_result(
         session_id,
         primary_invocation_id,
         review_invocation_id,
         usage,
         result,
         ownership
       ) do
    with {:ok, _event} <-
           Sessions.append_event(
             session_id,
             "review_invocation_completed",
             %{
               "invocation_id" => review_invocation_id,
               "primary_invocation_id" => primary_invocation_id,
               "role" => "review",
               "usage" => usage || %{}
             },
             parent_id: review_invocation_id,
             ownership: ownership
           ) do
      Sessions.append_event(
        session_id,
        "review_result",
        Map.merge(result, %{
          "invocation_id" => review_invocation_id,
          "primary_invocation_id" => primary_invocation_id,
          "role" => "review"
        }),
        version: 1,
        parent_id: review_invocation_id,
        ownership: ownership
      )
    end
  end

  defp handle_review_result(
         text,
         %{payload: %{"clean" => true}} = result,
         session_id,
         _adapter,
         _budgets,
         _invocations,
         ownership
       ) do
    with :ok <- persist_reviewed_answer(session_id, result, text, ownership) do
      {:ok, text}
    end
  end

  defp handle_review_result(
         _text,
         %{payload: %{"clean" => false, "findings" => findings}} = result,
         session_id,
         adapter,
         budgets,
         invocations,
         ownership
       ) do
    events = Sessions.events_after(session_id)

    with :ok <- persist_review_feedback(session_id, result, findings, events, ownership) do
      events = Sessions.events_after(session_id)
      projection = Projection.from_events(events)
      infer(session_id, projection, events, adapter, budgets, invocations + 1, ownership)
    end
  end

  defp persist_review_feedback(session_id, result, findings, events, ownership) do
    if Enum.any?(events, fn event ->
         event.type == "review_feedback" and
           event.payload["review_invocation_id"] == result.payload["invocation_id"]
       end) do
      :ok
    else
      content =
        "Final-diff review found supported issues. Address them and rerun affected verification: " <>
          Jason.encode!(findings)

      case Sessions.append_event(
             session_id,
             "review_feedback",
             %{
               "review_invocation_id" => result.payload["invocation_id"],
               "content" => content,
               "findings" => findings
             },
             version: 1,
             parent_id: result.payload["invocation_id"],
             ownership: ownership
           ) do
        {:ok, _event} -> :ok
        error -> error
      end
    end
  end

  defp persist_reviewed_answer(session_id, result, text, ownership) do
    invocation_id = result.payload["primary_invocation_id"]

    if Enum.any?(Sessions.events_after(session_id), fn event ->
         event.type == "assistant_message_completed" and
           event.payload["invocation_id"] == invocation_id
       end) do
      :ok
    else
      case Sessions.append_event(
             session_id,
             "assistant_message_completed",
             %{
               "role" => "assistant",
               "content" => text,
               "invocation_id" => invocation_id
             },
             ownership: ownership
           ) do
        {:ok, _event} -> :ok
        error -> error
      end
    end
  end

  defp continue_after_tools(session_id, adapter, budgets, invocations, ownership) do
    events = Sessions.events_after(session_id)
    projection = Projection.from_events(events)
    infer(session_id, projection, events, adapter, budgets, invocations + 1, ownership)
  end

  defp next_action(nil, nil), do: :infer
  defp next_action(%{sequence: invocation_sequence}, nil) when invocation_sequence > 0, do: :infer

  defp next_action(%{sequence: invocation_sequence}, %{sequence: response_sequence})
       when invocation_sequence > response_sequence,
       do: :infer

  defp next_action(_latest_invocation, latest_response), do: latest_response

  defp current_turn(events) do
    case List.last(Enum.filter(events, &(&1.type == "user_message"))) do
      nil -> []
      user_message -> Enum.filter(events, &(&1.sequence >= user_message.sequence))
    end
  end

  defp infer(session_id, projection, events, adapter, budgets, invocation, ownership) do
    mapping = projection.model_mapping || legacy_mapping(projection.model)
    primary = ModelMapping.role!(mapping, :primary)
    contract = Roles.fetch!(:primary, primary["role_contract"])

    tools =
      Tools.definitions_for_turn(
        contract.toolset_version,
        invocation,
        budgets[:max_continuations]
      )

    with :ok <- within_budget(invocation, usage(current_turn(events)), budgets),
         {:ok, capability_validation} <-
           adapter.validate_model(primary["model"], primary, contract),
         {:ok, request} <- resolve_request(session_id, primary),
         {:ok, invocation_id} <-
           start_invocation(
             session_id,
             invocation,
             mapping,
             primary,
             capability_validation,
             ownership
           ),
         :ok <- rehoming_boundary(),
         {:ok, response} <-
           Sessions.dispatch_if_owner(ownership, fn ->
             generate(adapter, request, transcript(events, contract), tools,
               timeout: budgets[:model_timeout],
               reasoning: primary["reasoning"]
             )
           end),
         {:ok, _event} <-
           persist_invocation_usage(session_id, invocation_id, response.usage, ownership),
         :ok <-
           within_budget(
             invocation,
             session_id |> Sessions.events_after() |> current_turn() |> usage(),
             budgets
           ),
         {:ok, _event} <-
           persist_model_response(session_id, invocation_id, response, mapping, ownership) do
      resume(session_id, adapter, budgets, ownership)
    end
  end

  defp transcript(events, contract) do
    system = %{"role" => "system", "content" => contract.prompt}

    primary_invocations =
      events
      |> Enum.filter(&(&1.type == "model_invocation_started"))
      |> MapSet.new(& &1.payload["invocation_id"])

    Enum.reduce(events, [system], fn event, messages ->
      case transcript_message(event, primary_invocations) do
        nil -> messages
        message -> messages ++ [message]
      end
    end)
  end

  defp transcript_message(%{type: "user_message", payload: payload}, _primary_invocations),
    do: %{"role" => "user", "content" => payload["content"]}

  defp transcript_message(%{type: "model_response", payload: payload}, _primary_invocations),
    do: assistant_message(payload)

  defp transcript_message(%{type: "review_feedback", payload: payload}, _primary_invocations),
    do: %{"role" => "user", "content" => payload["content"]}

  defp transcript_message(%{type: type, payload: payload}, primary_invocations)
       when type in ["tool_completed", "tool_failed"] do
    if MapSet.member?(primary_invocations, payload["invocation_id"]) do
      content =
        if type == "tool_completed", do: payload["output"], else: %{"error" => payload["error"]}

      %{
        "role" => "tool",
        "tool_call_id" => payload["tool_call_id"],
        "name" => payload["name"],
        "content" => content
      }
    end
  end

  defp transcript_message(_event, _primary_invocations), do: nil

  defp assistant_message(%{"assistant" => nil} = payload) do
    %{
      "role" => "assistant",
      "content" => payload["text"] || "",
      "tool_calls" => payload["tool_calls"] || []
    }
  end

  defp assistant_message(%{"assistant" => provider_state}),
    do: %{"role" => "assistant", "provider_state" => provider_state}

  defp start_invocation(
         session_id,
         continuation,
         mapping,
         primary,
         capability_validation,
         ownership
       ) do
    invocation_id = Ecto.UUID.generate()

    case Sessions.append_event(
           session_id,
           "model_invocation_started",
           %{
             "invocation_id" => invocation_id,
             "continuation" => continuation,
             "role" => "primary",
             "provider" => primary["provider"],
             "model" => primary["model"],
             "reasoning" => primary["reasoning"],
             "role_contract" => primary["role_contract"],
             "toolset_version" => primary["toolset_version"],
             "capability_validation" => capability_validation,
             "model_mapping" => mapping
           },
           version: 3,
           ownership: ownership
         ) do
      {:ok, _event} -> {:ok, invocation_id}
      error -> error
    end
  end

  defp persist_invocation_usage(session_id, invocation_id, usage, ownership) do
    Sessions.append_event(
      session_id,
      "model_invocation_completed",
      %{"invocation_id" => invocation_id, "usage" => usage || %{}},
      parent_id: invocation_id,
      ownership: ownership
    )
  end

  defp persist_model_response(session_id, invocation_id, response, mapping, ownership) do
    events = [
      {"assistant_message_started", %{"invocation_id" => invocation_id}, [ownership: ownership]},
      {"model_response",
       %{
         "invocation_id" => invocation_id,
         "text" => response.text,
         "tool_calls" => normalize_tool_calls(response.tool_calls),
         "usage" => response.usage || %{},
         "assistant" => Map.get(response, :assistant)
       }, [version: 2, ownership: ownership]}
    ]

    events =
      if response.text == "" or defer_final_answer?(response, mapping) do
        events
      else
        events ++
          [
            {"assistant_message_completed",
             %{
               "role" => "assistant",
               "content" => response.text,
               "invocation_id" => invocation_id
             }, [ownership: ownership]}
          ]
      end

    Sessions.append_events(session_id, events)
  end

  defp defer_final_answer?(response, _mapping), do: response.tool_calls == []

  defp normalize_tool_calls(calls) do
    Enum.map(calls, &%{"id" => &1.id, "name" => &1.name, "arguments" => &1.arguments})
  end

  defp execute_tools(
         session_id,
         runner_id,
         response,
         calls,
         adapter,
         mapping,
         budgets,
         ownership
       ) do
    with :ok <- validate_tool_calls(calls),
         :ok <- Phoenix.PubSub.subscribe(Kodo.PubSub, "runner_responses:#{runner_id}"),
         :ok <- Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session_id}"),
         :ok <- Runners.subscribe_lifecycle() do
      events = Sessions.events_after(session_id)

      invocation_id = response.payload["invocation_id"]

      context = %{
        session_id: session_id,
        runner_id: runner_id,
        invocation_id: invocation_id,
        calls: calls,
        events: events,
        adapter: adapter,
        mapping: mapping,
        budgets: budgets,
        timeout: budgets[:tool_timeout],
        ownership: ownership
      }

      Enum.reduce_while(Enum.with_index(calls), {:ok, []}, fn call_with_index, result ->
        reduce_tool_call(call_with_index, result, context)
      end)
    end
  end

  defp reduce_tool_call(
         {%{"name" => "delegate_search"} = call, _index},
         {:ok, results},
         context
       ) do
    case execute_search_tool(call, context) do
      {:ok, result} -> {:cont, {:ok, results ++ [result]}}
      {:error, :rehoming_requested} = error -> {:halt, error}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp reduce_tool_call({call, index}, {:ok, results}, context) do
    case execute_tool(
           context.session_id,
           context.runner_id,
           context.invocation_id,
           call,
           context.events,
           context.timeout,
           context.ownership
         ) do
      {:ok, result} ->
        {:cont, {:ok, results ++ [result]}}

      {:error, :rehoming_requested} = error ->
        {:halt, error}

      {:error, reason} ->
        halt_after_tool_failure(
          context.session_id,
          context.invocation_id,
          context.calls,
          index,
          call,
          reason,
          context.ownership
        )
    end
  end

  defp execute_search_tool(call, context) do
    facts = tool_facts(context.events, context.invocation_id, call["id"])

    case recorded_tool_result(facts, call["id"]) do
      nil -> execute_unrecorded_search_tool(call, facts, context)
      result -> result
    end
  end

  defp execute_unrecorded_search_tool(call, facts, context) do
    requested = Enum.find(facts, &(&1.type == "tool_requested"))
    request_id = if requested, do: requested.payload["request_id"], else: Ecto.UUID.generate()

    result =
      with {:ok, %{"question" => question}} <- Tools.request(call["name"], call["arguments"]),
           :ok <-
             persist_request(
               context.session_id,
               context.invocation_id,
               call,
               request_id,
               requested,
               context.ownership
             ),
           :ok <- rehoming_boundary(),
           :ok <-
             persist_started(
               context.session_id,
               context.invocation_id,
               call,
               request_id,
               facts,
               context.ownership
             ),
           {:ok, evidence} <- run_search(question, call, context),
           output = %{"result" => "search_evidence", "content" => evidence},
           {:ok, _event} <-
             Sessions.append_event(
               context.session_id,
               "tool_completed",
               %{
                 "tool_call_id" => call["id"],
                 "request_id" => request_id,
                 "name" => call["name"],
                 "output" => output,
                 "invocation_id" => context.invocation_id
               },
               parent_id: context.invocation_id,
               ownership: context.ownership
             ) do
        {:ok, %{tool_call_id: call["id"], name: call["name"], output: output}}
      end

    case result do
      {:error, :rehoming_requested} = error ->
        error

      {:error, reason} = error ->
        reconcile_tool_failure(
          context.session_id,
          context.invocation_id,
          call,
          facts,
          reason,
          error,
          context.ownership
        )

      success ->
        success
    end
  end

  defp run_search(question, parent_call, context) do
    search = ModelMapping.role!(context.mapping, :search)
    contract = Roles.fetch!(:search, search["role_contract"])

    with {:ok, capability_validation} <-
           context.adapter.validate_model(search["model"], search, contract) do
      state = %{
        parent_call: parent_call,
        search: search,
        contract: contract,
        capability_validation: capability_validation,
        context: context
      }

      resume_search(question, state)
    end
  end

  defp resume_search(question, state) do
    events = Sessions.events_after(state.context.session_id)
    replay = search_replay(events, state.parent_call["id"])

    base_messages = [
      %{"role" => "system", "content" => state.contract.prompt},
      %{"role" => "user", "content" => question}
    ]

    resume_search_response(List.last(replay.responses), base_messages, replay, state)
  end

  defp search_replay(events, delegation_id) do
    delegated =
      Enum.filter(events, fn event ->
        event.payload["role"] == "search" and
          event.payload["delegation_tool_call_id"] == delegation_id
      end)

    %{
      events: events,
      responses: Enum.filter(delegated, &(&1.type == "subagent_response")),
      starts: Enum.count(delegated, &(&1.type == "subagent_invocation_started")),
      tokens:
        delegated
        |> Enum.filter(&(&1.type == "subagent_invocation_completed"))
        |> Enum.sum_by(&token_count(&1.payload["usage"]))
    }
  end

  defp resume_search_response(nil, messages, replay, state) do
    run_search_continuation(messages, replay.starts + 1, replay.tokens, state)
  end

  defp resume_search_response(
         %{payload: %{"tool_calls" => [], "text" => text}},
         _messages,
         _replay,
         _state
       ),
       do: {:ok, text}

  defp resume_search_response(
         %{payload: %{"invocation_id" => invocation_id, "tool_calls" => calls}},
         base_messages,
         replay,
         state
       ) do
    with :ok <- validate_tool_calls(calls),
         :ok <- validate_role_tools(calls, state.contract),
         {:ok, _results} <- execute_search_calls(calls, invocation_id, state.context) do
      events = Sessions.events_after(state.context.session_id)
      messages = replayed_search_messages(base_messages, replay.responses, events)
      run_search_continuation(messages, replay.starts + 1, replay.tokens, state)
    end
  end

  defp replayed_search_messages(base_messages, responses, events) do
    Enum.reduce(responses, base_messages, fn response, messages ->
      payload = response.payload

      assistant =
        assistant_message(%{
          "assistant" => payload["assistant"],
          "text" => payload["text"],
          "tool_calls" => payload["tool_calls"]
        })

      tool_messages =
        Enum.flat_map(
          payload["tool_calls"],
          &search_tool_messages(events, payload["invocation_id"], &1)
        )

      messages ++ [assistant] ++ tool_messages
    end)
  end

  defp search_tool_messages(events, invocation_id, call) do
    case search_tool_message(events, invocation_id, call) do
      nil -> []
      message -> [message]
    end
  end

  defp search_tool_message(events, invocation_id, call) do
    events
    |> Enum.find(fn event ->
      event.payload["invocation_id"] == invocation_id and
        event.payload["tool_call_id"] == call["id"] and
        event.type in ["tool_completed", "tool_failed"]
    end)
    |> search_tool_event_message(call)
  end

  defp search_tool_event_message(nil, _call), do: nil

  defp search_tool_event_message(%{type: "tool_completed", payload: payload}, call) do
    search_tool_message(call, payload["output"])
  end

  defp search_tool_event_message(%{type: "tool_failed", payload: payload}, call) do
    search_tool_message(call, %{"error" => payload["error"]})
  end

  defp search_tool_message(call, content) do
    %{
      "role" => "tool",
      "tool_call_id" => call["id"],
      "name" => call["name"],
      "content" => content
    }
  end

  defp run_search_continuation(messages, continuation, tokens, state) do
    with :ok <- within_budget(continuation, tokens, state.contract.budget),
         :ok <- rehoming_boundary(),
         {:ok, request} <- resolve_request(state.context.session_id, state.search),
         {:ok, invocation_id} <-
           start_subagent_invocation(
             state.parent_call,
             state.search,
             state.contract,
             state.capability_validation,
             continuation,
             state.context
           ),
         :ok <- rehoming_boundary(),
         {:ok, response} <-
           Sessions.dispatch_if_owner(state.context.ownership, fn ->
             generate(
               state.context.adapter,
               request,
               messages,
               Tools.definitions_for_turn(
                 state.contract.toolset_version,
                 continuation,
                 state.contract.budget.max_continuations
               ),
               timeout: state.context.budgets[:model_timeout],
               reasoning: state.search["reasoning"]
             )
           end),
         {:ok, _event} <-
           persist_subagent_response(
             state.context.session_id,
             invocation_id,
             state.parent_call["id"],
             response,
             state.context.ownership
           ),
         tokens = tokens + token_count(response.usage),
         :ok <- within_budget(continuation, tokens, state.contract.budget) do
      continue_search(
        response,
        messages,
        invocation_id,
        continuation,
        tokens,
        state
      )
    end
  end

  defp continue_search(
         %{type: :final_answer, text: text},
         _messages,
         _invocation_id,
         _continuation,
         _tokens,
         _state
       ),
       do: {:ok, text}

  defp continue_search(
         %{type: :tool_calls, tool_calls: tool_calls} = response,
         messages,
         invocation_id,
         continuation,
         tokens,
         state
       ) do
    calls = normalize_tool_calls(tool_calls)

    with :ok <- validate_tool_calls(calls),
         :ok <- validate_role_tools(calls, state.contract),
         {:ok, results} <- execute_search_calls(calls, invocation_id, state.context) do
      tool_messages =
        Enum.map(results, fn result ->
          %{
            "role" => "tool",
            "tool_call_id" => result.tool_call_id,
            "name" => result.name,
            "content" => result.output
          }
        end)

      assistant =
        assistant_message(%{
          "assistant" => Map.get(response, :assistant),
          "text" => response.text,
          "tool_calls" => calls
        })

      next_messages = messages ++ [assistant] ++ tool_messages
      run_search_continuation(next_messages, continuation + 1, tokens, state)
    end
  end

  defp validate_role_tools(calls, contract) do
    allowed = MapSet.new(Tools.definitions(contract.toolset_version), & &1.name)

    case Enum.find(calls, &(not MapSet.member?(allowed, &1["name"]))) do
      nil -> :ok
      call -> {:error, {:tool_denied, call["name"]}}
    end
  end

  defp execute_search_calls(calls, invocation_id, context) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, results} ->
      events = Sessions.events_after(context.session_id)

      case execute_tool(
             context.session_id,
             context.runner_id,
             invocation_id,
             call,
             events,
             context.timeout,
             context.ownership
           ) do
        {:ok, result} -> {:cont, {:ok, results ++ [result]}}
        error -> {:halt, error}
      end
    end)
  end

  defp start_subagent_invocation(
         parent_call,
         search,
         contract,
         capability_validation,
         continuation,
         context
       ) do
    invocation_id = Ecto.UUID.generate()

    case Sessions.append_event(
           context.session_id,
           "subagent_invocation_started",
           %{
             "invocation_id" => invocation_id,
             "delegation_tool_call_id" => parent_call["id"],
             "continuation" => continuation,
             "role" => "search",
             "provider" => search["provider"],
             "model" => search["model"],
             "reasoning" => search["reasoning"],
             "role_contract" => contract.id,
             "toolset_version" => contract.toolset_version,
             "capability_validation" => capability_validation,
             "model_mapping" => context.mapping
           },
           version: 1,
           parent_id: context.invocation_id,
           ownership: context.ownership
         ) do
      {:ok, _event} -> {:ok, invocation_id}
      error -> error
    end
  end

  defp persist_subagent_response(
         session_id,
         invocation_id,
         delegation_tool_call_id,
         response,
         ownership
       ) do
    Sessions.append_events(session_id, [
      {"subagent_invocation_completed",
       %{
         "invocation_id" => invocation_id,
         "delegation_tool_call_id" => delegation_tool_call_id,
         "role" => "search",
         "usage" => response.usage || %{}
       }, [parent_id: invocation_id, ownership: ownership]},
      {"subagent_response",
       %{
         "invocation_id" => invocation_id,
         "delegation_tool_call_id" => delegation_tool_call_id,
         "role" => "search",
         "text" => response.text,
         "tool_calls" => normalize_tool_calls(response.tool_calls),
         "assistant" => Map.get(response, :assistant)
       }, [version: 1, parent_id: invocation_id, ownership: ownership]}
    ])
  end

  defp halt_after_tool_failure(
         session_id,
         invocation_id,
         calls,
         index,
         call,
         reason,
         ownership
       ) do
    case persist_skipped_tools(
           session_id,
           invocation_id,
           Enum.drop(calls, index + 1),
           call["id"],
           ownership
         ) do
      :ok -> {:halt, {:error, reason}}
      {:error, persistence_reason} -> {:halt, {:error, persistence_reason}}
    end
  end

  defp validate_tool_calls(calls) do
    ids = Enum.map(calls, & &1["id"])

    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) and
         length(ids) == MapSet.size(MapSet.new(ids)) do
      :ok
    else
      {:error, :invalid_tool_call_ids}
    end
  end

  defp execute_tool(session_id, runner_id, invocation_id, call, events, timeout, ownership) do
    facts = tool_facts(events, invocation_id, call["id"])

    case recorded_tool_result(facts, call["id"]) do
      nil ->
        execute_unrecorded_tool(
          session_id,
          runner_id,
          invocation_id,
          call,
          facts,
          timeout,
          ownership
        )

      result ->
        result
    end
  end

  defp tool_facts(events, invocation_id, call_id) do
    call_facts =
      Enum.filter(events, fn event ->
        (event.parent_id == invocation_id or event.payload["invocation_id"] == invocation_id) and
          event.payload["tool_call_id"] == call_id
      end)

    approval_ids =
      for %{type: "approval_requested", payload: payload} <- call_facts,
          do: payload["approval_id"]

    resolutions =
      Enum.filter(
        events,
        &(&1.type == "approval_resolved" and &1.payload["approval_id"] in approval_ids)
      )

    call_facts ++ resolutions
  end

  defp recorded_tool_result(facts, call_id) do
    case Enum.find(facts, &(&1.type == "tool_completed")) do
      nil -> recorded_tool_failure(facts)
      completed -> completed_tool_result(completed.payload, call_id)
    end
  end

  defp recorded_tool_failure(facts) do
    case Enum.find(facts, &(&1.type == "tool_failed")) do
      nil -> nil
      failed -> {:error, {:recorded_tool_failure, failed.payload["error"]}}
    end
  end

  defp completed_tool_result(payload, call_id),
    do: {:ok, %{tool_call_id: call_id, name: payload["name"], output: payload["output"]}}

  defp execute_unrecorded_tool(
         session_id,
         runner_id,
         invocation_id,
         call,
         facts,
         timeout,
         ownership
       ) do
    case execute_incomplete(
           session_id,
           runner_id,
           invocation_id,
           call,
           facts,
           timeout,
           ownership
         ) do
      {:error, :rehoming_requested} = error ->
        error

      {:error, reason} = error ->
        reconcile_tool_failure(
          session_id,
          invocation_id,
          call,
          facts,
          reason,
          error,
          ownership
        )

      result ->
        result
    end
  end

  defp reconcile_tool_failure(
         session_id,
         invocation_id,
         call,
         facts,
         reason,
         error,
         ownership
       ) do
    case persist_tool_failure(session_id, invocation_id, call, facts, reason, ownership) do
      :ok -> error
      {:error, persistence_reason} -> {:error, persistence_reason}
    end
  end

  defp execute_incomplete(
         session_id,
         runner_id,
         invocation_id,
         call,
         facts,
         timeout,
         ownership
       ) do
    name = call["name"]
    arguments = call["arguments"]
    requested = Enum.find(facts, &(&1.type == "tool_requested"))
    request_id = if requested, do: requested.payload["request_id"], else: Ecto.UUID.generate()

    with {:ok, request} <- Tools.request(name, arguments),
         :ok <- persist_request(session_id, invocation_id, call, request_id, requested, ownership),
         :ok <- rehoming_boundary(),
         :ok <- authorize_tool(session_id, invocation_id, call, facts, ownership),
         :ok <- persist_started(session_id, invocation_id, call, request_id, facts, ownership),
         {:ok, output} <-
           dispatch_and_await_response(
             runner_id,
             request_id,
             request,
             timeout,
             ownership
           ),
         {:ok, _event} <-
           Sessions.append_event(
             session_id,
             "tool_completed",
             %{
               "tool_call_id" => call["id"],
               "request_id" => request_id,
               "name" => name,
               "output" => output,
               "invocation_id" => invocation_id
             },
             parent_id: invocation_id,
             ownership: ownership
           ) do
      {:ok, %{tool_call_id: call["id"], name: name, output: output}}
    end
  end

  defp persist_request(
         _session_id,
         _invocation_id,
         _call,
         _request_id,
         %{type: "tool_requested"},
         _ownership
       ),
       do: :ok

  defp persist_request(session_id, invocation_id, call, request_id, nil, ownership) do
    case Sessions.append_event(
           session_id,
           "tool_requested",
           %{
             "tool_call_id" => call["id"],
             "request_id" => request_id,
             "name" => call["name"],
             "arguments" => call["arguments"],
             "invocation_id" => invocation_id
           },
           parent_id: invocation_id,
           ownership: ownership
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp persist_started(session_id, invocation_id, call, request_id, facts, ownership) do
    if Enum.any?(facts, &(&1.type == "tool_started")) do
      :ok
    else
      append_started(session_id, invocation_id, call, request_id, ownership)
    end
  end

  defp persist_tool_failure(session_id, invocation_id, call, facts, reason, ownership) do
    if Enum.any?(facts, &(&1.type == "tool_failed")) do
      :ok
    else
      requested = Enum.find(facts, &(&1.type == "tool_requested"))

      case Sessions.append_event(
             session_id,
             "tool_failed",
             %{
               "tool_call_id" => call["id"],
               "request_id" => requested && requested.payload["request_id"],
               "name" => call["name"],
               "invocation_id" => invocation_id,
               "error" => inspect(reason)
             },
             parent_id: invocation_id,
             ownership: ownership
           ) do
        {:ok, _event} -> :ok
        {:error, persistence_reason} -> {:error, persistence_reason}
      end
    end
  end

  defp persist_skipped_tools(session_id, invocation_id, calls, failed_call_id, ownership) do
    Enum.reduce_while(calls, :ok, fn call, :ok ->
      case persist_tool_failure(
             session_id,
             invocation_id,
             call,
             [],
             {:skipped_after_failure, failed_call_id},
             ownership
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp append_started(session_id, invocation_id, call, request_id, ownership) do
    case Sessions.append_event(
           session_id,
           "tool_started",
           %{
             "tool_call_id" => call["id"],
             "request_id" => request_id,
             "name" => call["name"],
             "invocation_id" => invocation_id
           },
           parent_id: invocation_id,
           ownership: ownership
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp authorize_tool(session_id, invocation_id, call, facts, ownership) do
    case Tools.authorization(
           Sessions.get_session!(session_id).approval_policy,
           call["name"],
           call["arguments"]
         ) do
      :allow -> :ok
      :deny -> {:error, {:tool_denied, call["name"]}}
      :approval -> await_approval(session_id, invocation_id, call, facts, ownership)
    end
  end

  defp await_approval(session_id, invocation_id, call, facts, ownership) do
    requested = List.last(Enum.filter(facts, &(&1.type == "approval_requested")))
    resolved = List.last(Enum.filter(facts, &(&1.type == "approval_resolved")))

    cond do
      resolved && resolved.payload["decision"] == "approved" ->
        :ok

      resolved ->
        {:error, :approval_denied}

      requested ->
        with :ok <- rehoming_boundary(),
             do: receive_approval(requested.payload["approval_id"])

      true ->
        approval_id = Ecto.UUID.generate()

        payload = %{
          "approval_id" => approval_id,
          "tool_call_id" => call["id"],
          "name" => call["name"],
          "arguments" => call["arguments"],
          "description" => "Run #{call["name"]}"
        }

        with {:ok, _} <-
               Sessions.request_approval(session_id, payload,
                 parent_id: invocation_id,
                 ownership: ownership
               ),
             :ok <- rehoming_boundary(),
             do: receive_approval(approval_id)
    end
  end

  defp receive_approval(approval_id) do
    receive do
      :rehoming_requested ->
        {:error, :rehoming_requested}

      {:session_event,
       %{
         type: "approval_resolved",
         payload: %{"approval_id" => ^approval_id, "decision" => "approved"}
       }} ->
        :ok

      {:session_event, %{type: "approval_resolved", payload: %{"approval_id" => ^approval_id}}} ->
        {:error, :approval_denied}
    end
  end

  # A drain only interrupts the loop after its next operation has a durable replay point. External
  # model and tool effects are allowed to finish so a replacement never races an in-flight effect.
  defp rehoming_boundary do
    receive do
      :rehoming_requested -> {:error, :rehoming_requested}
    after
      0 -> :ok
    end
  end

  defp dispatch_and_await_response(runner_id, request_id, request, timeout, ownership) do
    {monitor_ref, _members} = Kodo.Cluster.Discovery.monitor_runner(runner_id)

    try do
      with :ok <- dispatch_when_connected(runner_id, request_id, request, ownership, monitor_ref),
           do:
             await_response(
               runner_id,
               request_id,
               request,
               timeout,
               ownership,
               monitor_ref
             )
    after
      Kodo.Cluster.Discovery.demonitor(monitor_ref)
    end
  end

  defp dispatch_when_connected(runner_id, request_id, request, ownership, monitor_ref) do
    envelope = %{
      "protocol_version" => @protocol_version,
      "request_id" => request_id,
      "authority" => RunnerProtocol.authority_lease(ownership),
      "request" => request
    }

    with result <-
           Sessions.dispatch_if_owner(ownership, fn -> Runners.dispatch(runner_id, envelope) end) do
      case result do
        :ok ->
          :ok

        {:error, :offline} ->
          receive do
            {:runner_connected, %{id: ^runner_id}} ->
              dispatch_when_connected(runner_id, request_id, request, ownership, monitor_ref)

            {^monitor_ref, :join, {:runner, ^runner_id}, _pids} ->
              dispatch_when_connected(runner_id, request_id, request, ownership, monitor_ref)
          end

        error ->
          error
      end
    end
  end

  defp await_response(runner_id, request_id, request, timeout, ownership, monitor_ref) do
    deadline = System.monotonic_time(:millisecond) + timeout

    await_response_until(
      runner_id,
      request_id,
      request,
      deadline,
      ownership,
      monitor_ref
    )
  end

  defp await_response_until(
         runner_id,
         request_id,
         request,
         deadline,
         ownership,
         monitor_ref
       ) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:runner_tool_response, ^runner_id,
       %{
         "protocol_version" => @protocol_version,
         "request_id" => ^request_id,
         "status" => "success",
         "response" => response
       }} ->
        case RunnerProtocol.validate_tool_response(request, response) do
          {:ok, _validated} -> {:ok, response}
          :error -> {:error, :invalid_runner_response}
        end

      {:runner_tool_response, ^runner_id,
       %{"request_id" => ^request_id, "status" => "error", "error" => error}} ->
        {:error, {:runner, error}}

      {:runner_tool_response, ^runner_id, %{"request_id" => ^request_id}} ->
        {:error, :invalid_runner_response}

      {:runner_connected, %{id: ^runner_id}} ->
        case dispatch_when_connected(runner_id, request_id, request, ownership, monitor_ref) do
          :ok ->
            await_response_until(
              runner_id,
              request_id,
              request,
              deadline,
              ownership,
              monitor_ref
            )

          error ->
            error
        end

      {^monitor_ref, :join, {:runner, ^runner_id}, _pids} ->
        case dispatch_when_connected(runner_id, request_id, request, ownership, monitor_ref) do
          :ok ->
            await_response_until(
              runner_id,
              request_id,
              request,
              deadline,
              ownership,
              monitor_ref
            )

          error ->
            error
        end
    after
      remaining -> {:error, :tool_timeout}
    end
  end

  defp usage(events) do
    completed = Enum.filter(events, &(&1.type == "model_invocation_completed"))
    completed_ids = MapSet.new(completed, & &1.payload["invocation_id"])

    legacy_responses =
      Enum.filter(events, fn event ->
        event.type == "model_response" and
          not MapSet.member?(completed_ids, event.payload["invocation_id"])
      end)

    Enum.sum(
      Enum.map(completed, &token_count(&1.payload["usage"])) ++
        Enum.map(legacy_responses, &token_count(&1.payload["usage"]))
    )
  end

  defp token_count(nil), do: 0
  defp token_count(usage), do: usage[:total_tokens] || usage["total_tokens"] || 0

  defp resolve_request(session_id, role) do
    with {:ok, scope} <- Sessions.owner_scope(session_id),
         {:ok, model, reference} <- LLM.resolve_integration(scope, role["model"]) do
      {:ok, %{scope: scope, model: model, reference: reference}}
    end
  end

  defp generate(adapter, request, messages, tools, opts) do
    LLM.generate(
      request.scope,
      request.model,
      request.reference,
      messages,
      tools,
      Keyword.put(opts, :adapter, adapter)
    )
  end

  defp generate_object(adapter, request, messages, schema, opts) do
    LLM.generate_object(
      request.scope,
      request.model,
      request.reference,
      messages,
      schema,
      Keyword.put(opts, :adapter, adapter)
    )
  end

  defp within_budget(invocations, tokens, budgets) do
    cond do
      invocations > budgets[:max_continuations] -> {:error, :continuation_budget_exceeded}
      tokens > budgets[:max_tokens] -> {:error, :token_budget_exceeded}
      true -> :ok
    end
  end

  defp legacy_mapping(model) do
    ModelMapping.balanced([{"session", %{primary: %{model: model}}}])
  end
end
