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
    resume(session_id, adapter, budgets)
  end

  defp resume(session_id, adapter, budgets) do
    events = Sessions.events_after(session_id)
    projection = Projection.from_events(events)
    turn_events = current_turn(events)
    responses = Enum.filter(turn_events, &(&1.type == "model_response"))
    invocations = Enum.count(turn_events, &(&1.type == "model_invocation_started"))
    tokens = usage(turn_events)

    latest_invocation =
      List.last(Enum.filter(turn_events, &(&1.type == "model_invocation_started")))

    latest_response = List.last(responses)

    with :ok <- within_budget(invocations, tokens, budgets) do
      case next_action(latest_invocation, latest_response) do
        :infer ->
          infer(session_id, projection, events, adapter, budgets, invocations + 1)

        %{payload: %{"tool_calls" => calls}} = response when calls != [] ->
          with {:ok, _results} <-
                 execute_tools(
                   session_id,
                   projection.runner_id,
                   response,
                   calls,
                   budgets
                 ) do
            refreshed_events = Sessions.events_after(session_id)
            refreshed_projection = Projection.from_events(refreshed_events)

            infer(
              session_id,
              refreshed_projection,
              refreshed_events,
              adapter,
              budgets,
              invocations + 1
            )
          end

        %{payload: %{"tool_calls" => []} = payload} ->
          {:ok, payload["text"]}
      end
    end
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

  defp infer(session_id, projection, events, adapter, budgets, invocation) do
    with :ok <- within_budget(invocation, usage(current_turn(events)), budgets),
         {:ok, invocation_id} <- start_invocation(session_id, invocation),
         {:ok, response} <-
           adapter.generate(projection.model, transcript(events), Tools.definitions(),
             timeout: budgets[:model_timeout]
           ),
         {:ok, _event} <- persist_invocation_usage(session_id, invocation_id, response.usage),
         :ok <-
           within_budget(
             invocation,
             session_id |> Sessions.events_after() |> current_turn() |> usage(),
             budgets
           ),
         {:ok, _event} <- persist_model_response(session_id, invocation_id, response) do
      resume(session_id, adapter, budgets)
    end
  end

  defp transcript(events) do
    system = %{"role" => "system", "content" => system_prompt()}

    Enum.reduce(events, [system], fn event, messages ->
      case event do
        %{type: "user_message", payload: payload} ->
          messages ++ [%{"role" => "user", "content" => payload["content"]}]

        %{type: "model_response", payload: payload} ->
          assistant =
            case payload["assistant"] do
              nil ->
                %{
                  "role" => "assistant",
                  "content" => payload["text"] || "",
                  "tool_calls" => payload["tool_calls"] || []
                }

              provider_state ->
                %{"role" => "assistant", "provider_state" => provider_state}
            end

          messages ++ [assistant]

        %{type: type, payload: payload} when type in ["tool_completed", "tool_failed"] ->
          content =
            if type == "tool_completed",
              do: payload["output"],
              else: %{"error" => payload["error"]}

          messages ++
            [
              %{
                "role" => "tool",
                "tool_call_id" => payload["tool_call_id"],
                "name" => payload["name"],
                "content" => content
              }
            ]

        _ ->
          messages
      end
    end)
  end

  defp start_invocation(session_id, continuation) do
    invocation_id = Ecto.UUID.generate()

    case Sessions.append_event(session_id, "model_invocation_started", %{
           "invocation_id" => invocation_id,
           "continuation" => continuation
         }) do
      {:ok, _event} -> {:ok, invocation_id}
      error -> error
    end
  end

  defp persist_invocation_usage(session_id, invocation_id, usage) do
    Sessions.append_event(
      session_id,
      "model_invocation_completed",
      %{"invocation_id" => invocation_id, "usage" => usage || %{}},
      parent_id: invocation_id
    )
  end

  defp persist_model_response(session_id, invocation_id, response) do
    events = [
      {"assistant_message_started", %{"invocation_id" => invocation_id}, []},
      {"model_response",
       %{
         "invocation_id" => invocation_id,
         "text" => response.text,
         "tool_calls" => normalize_tool_calls(response.tool_calls),
         "usage" => response.usage || %{},
         "assistant" => Map.get(response, :assistant)
       }, [version: 2]}
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
             }, []}
          ]
      end

    Sessions.append_events(session_id, events)
  end

  defp normalize_tool_calls(calls) do
    Enum.map(calls, &%{"id" => &1.id, "name" => &1.name, "arguments" => &1.arguments})
  end

  defp execute_tools(session_id, runner_id, response, calls, budgets) do
    with :ok <- validate_tool_calls(calls),
         :ok <- Phoenix.PubSub.subscribe(Kodo.PubSub, "runner_responses:#{runner_id}"),
         :ok <- Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session_id}"),
         :ok <- Runners.subscribe_lifecycle() do
      events = Sessions.events_after(session_id)

      Enum.reduce_while(Enum.with_index(calls), {:ok, []}, fn {call, index}, {:ok, results} ->
        case execute_tool(
               session_id,
               runner_id,
               response.payload["invocation_id"],
               call,
               events,
               budgets[:tool_timeout]
             ) do
          {:ok, result} ->
            {:cont, {:ok, results ++ [result]}}

          {:error, reason} ->
            case persist_skipped_tools(
                   session_id,
                   response.payload["invocation_id"],
                   Enum.drop(calls, index + 1),
                   call["id"]
                 ) do
              :ok -> {:halt, {:error, reason}}
              {:error, persistence_reason} -> {:halt, {:error, persistence_reason}}
            end
        end
      end)
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

  defp execute_tool(session_id, runner_id, invocation_id, call, events, timeout) do
    call_id = call["id"]

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

    facts = call_facts ++ resolutions

    cond do
      completed = Enum.find(facts, &(&1.type == "tool_completed")) ->
        payload = completed.payload
        {:ok, %{tool_call_id: call_id, name: payload["name"], output: payload["output"]}}

      failed = Enum.find(facts, &(&1.type == "tool_failed")) ->
        {:error, {:recorded_tool_failure, failed.payload["error"]}}

      true ->
        case execute_incomplete(session_id, runner_id, invocation_id, call, facts, timeout) do
          {:error, reason} = error ->
            case persist_tool_failure(session_id, invocation_id, call, facts, reason) do
              :ok -> error
              {:error, persistence_reason} -> {:error, persistence_reason}
            end

          result ->
            result
        end
    end
  end

  defp execute_incomplete(session_id, runner_id, invocation_id, call, facts, timeout) do
    name = call["name"]
    arguments = call["arguments"]
    requested = Enum.find(facts, &(&1.type == "tool_requested"))
    request_id = if requested, do: requested.payload["request_id"], else: Ecto.UUID.generate()

    with {:ok, request} <- Tools.request(name, arguments),
         :ok <- persist_request(session_id, invocation_id, call, request_id, requested),
         :ok <- authorize_tool(session_id, invocation_id, call, facts),
         :ok <- persist_started(session_id, invocation_id, call, request_id, facts),
         :ok <- dispatch_when_connected(runner_id, request_id, request),
         {:ok, output} <- await_response(runner_id, request_id, request, timeout),
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
             parent_id: invocation_id
           ) do
      {:ok, %{tool_call_id: call["id"], name: name, output: output}}
    end
  end

  defp persist_request(_session_id, _invocation_id, _call, _request_id, %{type: "tool_requested"}),
       do: :ok

  defp persist_request(session_id, invocation_id, call, request_id, nil) do
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
           parent_id: invocation_id
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp persist_started(session_id, invocation_id, call, request_id, facts) do
    if Enum.any?(facts, &(&1.type == "tool_started")) do
      :ok
    else
      append_started(session_id, invocation_id, call, request_id)
    end
  end

  defp persist_tool_failure(session_id, invocation_id, call, facts, reason) do
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
             parent_id: invocation_id
           ) do
        {:ok, _event} -> :ok
        {:error, persistence_reason} -> {:error, persistence_reason}
      end
    end
  end

  defp persist_skipped_tools(session_id, invocation_id, calls, failed_call_id) do
    Enum.reduce_while(calls, :ok, fn call, :ok ->
      case persist_tool_failure(
             session_id,
             invocation_id,
             call,
             [],
             {:skipped_after_failure, failed_call_id}
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp append_started(session_id, invocation_id, call, request_id) do
    case Sessions.append_event(
           session_id,
           "tool_started",
           %{
             "tool_call_id" => call["id"],
             "request_id" => request_id,
             "name" => call["name"],
             "invocation_id" => invocation_id
           },
           parent_id: invocation_id
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp authorize_tool(session_id, invocation_id, call, facts) do
    case Tools.authorization(
           Sessions.get_session!(session_id).approval_policy,
           call["name"],
           call["arguments"]
         ) do
      :allow -> :ok
      :deny -> {:error, {:tool_denied, call["name"]}}
      :approval -> await_approval(session_id, invocation_id, call, facts)
    end
  end

  defp await_approval(session_id, invocation_id, call, facts) do
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

        with {:ok, _} <- Sessions.request_approval(session_id, payload, parent_id: invocation_id),
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

  defp dispatch_when_connected(runner_id, request_id, request) do
    envelope = %{
      "protocol_version" => @protocol_version,
      "request_id" => request_id,
      "request" => request
    }

    case Runners.dispatch(runner_id, envelope) do
      :ok ->
        :ok

      {:error, :offline} ->
        receive do
          {:runner_connected, %{id: ^runner_id}} ->
            dispatch_when_connected(runner_id, request_id, request)
        end

      error ->
        error
    end
  end

  defp await_response(runner_id, request_id, request, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_response_until(runner_id, request_id, request, deadline)
  end

  defp await_response_until(runner_id, request_id, request, deadline) do
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
        case dispatch_when_connected(runner_id, request_id, request) do
          :ok -> await_response_until(runner_id, request_id, request, deadline)
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
