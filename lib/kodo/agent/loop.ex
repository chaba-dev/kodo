defmodule Kodo.Agent.Loop do
  @moduledoc "Explicit, budgeted primary-agent model and runner continuation loop."

  alias Kodo.Agent.Tools
  alias Kodo.LLM
  alias Kodo.RunnerProtocol
  alias Kodo.Runners
  alias Kodo.Sessions
  alias Kodo.Sessions.Projection

  @protocol_version RunnerProtocol.version()
  @first_continuation 1
  @continuation_step 1
  @no_tokens 0

  def run(session_id, opts \\ []) do
    projection = session_id |> Sessions.events_after() |> Projection.from_events()
    budgets = Keyword.get(opts, :budgets, Application.fetch_env!(:kodo, :agent_budgets))
    adapter = Keyword.get(opts, :adapter, LLM.adapter())
    messages = [%{"role" => "system", "content" => system_prompt()} | projection.messages]

    with {:ok, invocation_id} <- start_invocation(session_id, @first_continuation),
         {:ok, response} <-
           adapter.generate(projection.model, messages, Tools.definitions(),
             timeout: budgets[:model_timeout]
           ) do
      continue(
        session_id,
        projection,
        adapter,
        response,
        invocation_id,
        budgets,
        @first_continuation,
        @no_tokens
      )
    end
  end

  defp continue(
         session_id,
         projection,
         adapter,
         response,
         invocation_id,
         budgets,
         continuation,
         tokens
       ) do
    tokens = tokens + token_count(response.usage)

    with :ok <- within_budget(continuation, tokens, budgets),
         {:ok, _event} <- persist_model_response(session_id, invocation_id, response) do
      handle_response(
        session_id,
        projection,
        adapter,
        response,
        invocation_id,
        budgets,
        continuation,
        tokens
      )
    end
  end

  defp handle_response(
         _session_id,
         _projection,
         _adapter,
         %{type: :final_answer} = response,
         _invocation_id,
         _budgets,
         _continuation,
         _tokens
       ) do
    {:ok, response.text}
  end

  defp handle_response(
         session_id,
         projection,
         adapter,
         %{type: :tool_calls} = response,
         invocation_id,
         budgets,
         continuation,
         tokens
       ) do
    next_continuation = continuation + @continuation_step

    with {:ok, results} <-
           execute_tools(
             session_id,
             projection.runner_id,
             invocation_id,
             response.tool_calls,
             budgets
           ),
         {:ok, next_invocation_id} <- start_invocation(session_id, next_continuation),
         {:ok, next_response} <-
           adapter.continue(
             projection.model,
             response.continuation,
             results,
             Tools.definitions(),
             timeout: budgets[:model_timeout]
           ) do
      continue(
        session_id,
        projection,
        adapter,
        next_response,
        next_invocation_id,
        budgets,
        next_continuation,
        tokens
      )
    end
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

  defp persist_model_response(session_id, invocation_id, response) do
    with {:ok, _event} <-
           Sessions.append_event(session_id, "assistant_message_started", %{
             "invocation_id" => invocation_id
           }),
         {:ok, _event} <-
           Sessions.append_event(session_id, "model_response", %{
             "invocation_id" => invocation_id,
             "text" => response.text,
             "tool_calls" => normalize_tool_calls(response.tool_calls),
             "usage" => response.usage || %{}
           }) do
      persist_assistant_text(session_id, invocation_id, response.text)
    end
  end

  defp persist_assistant_text(_session_id, _invocation_id, ""), do: {:ok, nil}

  defp persist_assistant_text(session_id, invocation_id, text) do
    Sessions.append_event(session_id, "assistant_message_completed", %{
      "role" => "assistant",
      "content" => text,
      "invocation_id" => invocation_id
    })
  end

  defp normalize_tool_calls(calls) do
    Enum.map(calls, fn call ->
      %{"id" => call.id, "name" => call.name, "arguments" => call.arguments}
    end)
  end

  defp execute_tools(session_id, runner_id, invocation_id, calls, budgets) do
    with :ok <- Phoenix.PubSub.subscribe(Kodo.PubSub, "runner_responses:#{runner_id}"),
         :ok <- Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session_id}") do
      Enum.reduce_while(calls, {:ok, []}, fn call, result ->
        execute_next_tool(
          call,
          result,
          session_id,
          runner_id,
          invocation_id,
          budgets[:tool_timeout]
        )
      end)
    end
  end

  defp execute_next_tool(call, {:ok, results}, session_id, runner_id, invocation_id, timeout) do
    case execute_tool(session_id, runner_id, invocation_id, call, timeout) do
      {:ok, result} -> {:cont, {:ok, results ++ [result]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp execute_tool(
         session_id,
         runner_id,
         invocation_id,
         %{id: call_id, name: name, arguments: arguments},
         timeout
       )
       when is_binary(call_id) and is_binary(name) and is_map(arguments) do
    request_id = Ecto.UUID.generate()

    with {:ok, request} <- Tools.request(name, arguments),
         {:ok, _event} <-
           Sessions.append_event(
             session_id,
             "tool_requested",
             %{
               "tool_call_id" => call_id,
               "request_id" => request_id,
               "name" => name,
               "arguments" => arguments,
               "invocation_id" => invocation_id
             },
             parent_id: invocation_id
           ),
         :ok <- authorize_tool(session_id, invocation_id, call_id, name, arguments),
         :ok <- dispatch(runner_id, request_id, request),
         {:ok, _event} <-
           Sessions.append_event(
             session_id,
             "tool_started",
             %{
               "tool_call_id" => call_id,
               "request_id" => request_id,
               "name" => name,
               "invocation_id" => invocation_id
             },
             parent_id: invocation_id
           ),
         {:ok, output} <- await_response(runner_id, request_id, timeout),
         {:ok, _event} <-
           Sessions.append_event(
             session_id,
             "tool_completed",
             %{
               "tool_call_id" => call_id,
               "request_id" => request_id,
               "name" => name,
               "output" => output,
               "invocation_id" => invocation_id
             },
             parent_id: invocation_id
           ) do
      {:ok, %{tool_call_id: call_id, name: name, output: output}}
    else
      {:error, reason} = error ->
        persist_tool_failure(session_id, invocation_id, call_id, request_id, name, reason)
        error
    end
  end

  defp execute_tool(session_id, _runner_id, invocation_id, call, _timeout) do
    persist_tool_failure(session_id, invocation_id, nil, nil, nil, {:invalid_tool_call, call})
    {:error, :invalid_tool_call}
  end

  defp dispatch(runner_id, request_id, request) do
    Runners.dispatch(runner_id, %{
      "protocol_version" => RunnerProtocol.version(),
      "request_id" => request_id,
      "request" => request
    })
  end

  defp authorize_tool(session_id, invocation_id, call_id, name, arguments) do
    policy = session_id |> Sessions.get_session!() |> Map.fetch!(:approval_policy)

    case Tools.authorization(policy, name, arguments) do
      :allow -> :ok
      :deny -> {:error, {:tool_denied, policy, name}}
      :approval -> await_approval(session_id, invocation_id, call_id, name, arguments)
    end
  end

  defp await_approval(session_id, invocation_id, call_id, name, arguments) do
    approval_id = Ecto.UUID.generate()

    with {:ok, {_event, _status_event}} <-
           Sessions.request_approval(
             session_id,
             %{
               "approval_id" => approval_id,
               "tool_call_id" => call_id,
               "name" => name,
               "arguments" => arguments,
               "description" => approval_description(name, arguments)
             },
             parent_id: invocation_id
           ) do
      receive do
        {:session_event,
         %{
           type: "approval_resolved",
           payload: %{"approval_id" => ^approval_id, "decision" => "approved"}
         }} ->
          :ok

        {:session_event,
         %{
           type: "approval_resolved",
           payload: %{"approval_id" => ^approval_id, "decision" => "denied"}
         }} ->
          {:error, :approval_denied}
      end
    end
  end

  defp approval_description("start_command", %{"command" => command}),
    do: "Run command: #{command}"

  defp approval_description("apply_patch", _arguments), do: "Apply a patch to the workspace"
  defp approval_description(name, _arguments), do: "Run #{name}"

  defp persist_tool_failure(session_id, invocation_id, call_id, request_id, name, reason) do
    _ =
      Sessions.append_event(
        session_id,
        "tool_failed",
        %{
          "tool_call_id" => call_id,
          "request_id" => request_id,
          "name" => name,
          "invocation_id" => invocation_id,
          "error" => inspect(reason)
        },
        parent_id: invocation_id
      )
  end

  defp await_response(runner_id, request_id, timeout) do
    receive do
      {:runner_tool_response, ^runner_id,
       %{
         "protocol_version" => protocol_version,
         "request_id" => ^request_id,
         "status" => "success",
         "response" => response
       }}
      when protocol_version == @protocol_version ->
        {:ok, response}

      {:runner_tool_response, ^runner_id,
       %{
         "protocol_version" => protocol_version,
         "request_id" => ^request_id,
         "status" => "error",
         "error" => error
       }}
      when protocol_version == @protocol_version ->
        {:error, {:runner, error}}

      {:runner_tool_response, ^runner_id, %{"request_id" => ^request_id}} ->
        {:error, :invalid_runner_response}
    after
      timeout -> {:error, :tool_timeout}
    end
  end

  defp within_budget(continuation, tokens, budgets) do
    cond do
      continuation > budgets[:max_continuations] -> {:error, :continuation_budget_exceeded}
      tokens > budgets[:max_tokens] -> {:error, :token_budget_exceeded}
      true -> :ok
    end
  end

  defp token_count(nil), do: @no_tokens

  defp token_count(usage),
    do: usage[:total_tokens] || usage["total_tokens"] || @no_tokens

  defp system_prompt do
    "You are Kodo's primary coding agent. Inspect evidence, make the smallest correct patch, and verify it."
  end
end
