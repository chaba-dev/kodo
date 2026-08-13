defmodule Kodo.Agent.Loop do
  @moduledoc "Event-driven, restartable primary-agent model and runner loop."

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
    case execute_tools(session_id, projection.runner_id, response, calls, budgets, ownership) do
      {:ok, _results} ->
        continue_after_tools(session_id, adapter, budgets, invocations, ownership)

      error ->
        error
    end
  end

  defp resume_action(
         %{payload: %{"tool_calls" => [], "text" => text}},
         _session_id,
         _projection,
         _events,
         _adapter,
         _budgets,
         _invocations,
         _ownership
       ),
       do: {:ok, text}

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
    with :ok <- within_budget(invocation, usage(current_turn(events)), budgets),
         {:ok, invocation_id} <- start_invocation(session_id, invocation, ownership),
         {:ok, response} <-
           Sessions.dispatch_if_owner(ownership, fn ->
             adapter.generate(projection.model, transcript(events), Tools.definitions(),
               timeout: budgets[:model_timeout]
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
         {:ok, _event} <- persist_model_response(session_id, invocation_id, response, ownership) do
      resume(session_id, adapter, budgets, ownership)
    end
  end

  defp transcript(events) do
    system = %{"role" => "system", "content" => system_prompt()}

    Enum.reduce(events, [system], fn event, messages ->
      case transcript_message(event) do
        nil -> messages
        message -> messages ++ [message]
      end
    end)
  end

  defp transcript_message(%{type: "user_message", payload: payload}),
    do: %{"role" => "user", "content" => payload["content"]}

  defp transcript_message(%{type: "model_response", payload: payload}),
    do: assistant_message(payload)

  defp transcript_message(%{type: type, payload: payload})
       when type in ["tool_completed", "tool_failed"] do
    content =
      if type == "tool_completed", do: payload["output"], else: %{"error" => payload["error"]}

    %{
      "role" => "tool",
      "tool_call_id" => payload["tool_call_id"],
      "name" => payload["name"],
      "content" => content
    }
  end

  defp transcript_message(_event), do: nil

  defp assistant_message(%{"assistant" => nil} = payload) do
    %{
      "role" => "assistant",
      "content" => payload["text"] || "",
      "tool_calls" => payload["tool_calls"] || []
    }
  end

  defp assistant_message(%{"assistant" => provider_state}),
    do: %{"role" => "assistant", "provider_state" => provider_state}

  defp start_invocation(session_id, continuation, ownership) do
    invocation_id = Ecto.UUID.generate()

    case Sessions.append_event(
           session_id,
           "model_invocation_started",
           %{
             "invocation_id" => invocation_id,
             "continuation" => continuation
           },
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

  defp persist_model_response(session_id, invocation_id, response, ownership) do
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
      if response.text == "" do
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

  defp normalize_tool_calls(calls) do
    Enum.map(calls, &%{"id" => &1.id, "name" => &1.name, "arguments" => &1.arguments})
  end

  defp execute_tools(session_id, runner_id, response, calls, budgets, ownership) do
    with :ok <- validate_tool_calls(calls),
         :ok <- Phoenix.PubSub.subscribe(Kodo.PubSub, "runner_responses:#{runner_id}"),
         :ok <- Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session_id}"),
         :ok <- Runners.subscribe_lifecycle() do
      events = Sessions.events_after(session_id)

      invocation_id = response.payload["invocation_id"]

      Enum.reduce_while(Enum.with_index(calls), {:ok, []}, fn call_with_index, result ->
        reduce_tool_call(
          call_with_index,
          result,
          session_id,
          runner_id,
          invocation_id,
          calls,
          events,
          budgets[:tool_timeout],
          ownership
        )
      end)
    end
  end

  defp reduce_tool_call(
         {call, index},
         {:ok, results},
         session_id,
         runner_id,
         invocation_id,
         calls,
         events,
         timeout,
         ownership
       ) do
    case execute_tool(session_id, runner_id, invocation_id, call, events, timeout, ownership) do
      {:ok, result} ->
        {:cont, {:ok, results ++ [result]}}

      {:error, reason} ->
        halt_after_tool_failure(
          session_id,
          invocation_id,
          calls,
          index,
          call,
          reason,
          ownership
        )
    end
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
         :ok <- authorize_tool(session_id, invocation_id, call, facts, ownership),
         :ok <- persist_started(session_id, invocation_id, call, request_id, facts, ownership),
         :ok <- dispatch_when_connected(runner_id, request_id, request, ownership),
         {:ok, output} <- await_response(runner_id, request_id, request, timeout, ownership),
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
        receive_approval(requested.payload["approval_id"])

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
             do: receive_approval(approval_id)
    end
  end

  defp receive_approval(approval_id) do
    receive do
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

  defp dispatch_when_connected(runner_id, request_id, request, ownership) do
    envelope = %{
      "protocol_version" => @protocol_version,
      "request_id" => request_id,
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
              dispatch_when_connected(runner_id, request_id, request, ownership)
          end

        error ->
          error
      end
    end
  end

  defp await_response(runner_id, request_id, request, timeout, ownership) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_response_until(runner_id, request_id, request, deadline, ownership)
  end

  defp await_response_until(runner_id, request_id, request, deadline, ownership) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:runner_tool_response, ^runner_id,
       %{
         "protocol_version" => @protocol_version,
         "request_id" => ^request_id,
         "status" => "success",
         "response" => response
       }} ->
        {:ok, response}

      {:runner_tool_response, ^runner_id,
       %{"request_id" => ^request_id, "status" => "error", "error" => error}} ->
        {:error, {:runner, error}}

      {:runner_tool_response, ^runner_id, %{"request_id" => ^request_id}} ->
        {:error, :invalid_runner_response}

      {:runner_connected, %{id: ^runner_id}} ->
        case dispatch_when_connected(runner_id, request_id, request, ownership) do
          :ok -> await_response_until(runner_id, request_id, request, deadline, ownership)
          error -> error
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

  defp within_budget(invocations, tokens, budgets) do
    cond do
      invocations > budgets[:max_continuations] -> {:error, :continuation_budget_exceeded}
      tokens > budgets[:max_tokens] -> {:error, :token_budget_exceeded}
      true -> :ok
    end
  end

  defp system_prompt,
    do:
      "You are Kodo's primary coding agent. Inspect evidence, make the smallest correct patch, and verify it."
end
