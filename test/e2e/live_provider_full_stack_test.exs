defmodule Kodo.E2E.LiveProviderFullStackTest do
  use Kodo.DataCase, async: false

  alias Kodo.Sessions
  alias Kodo.Test.FullStackCase, as: Stack

  @moduletag live_provider: true, timeout: 240_000

  @live_session_timeout 180_000
  @prompt "Change greeting.txt from its current misspelling to exactly hello followed by a newline. Run a focused shell command to verify the exact file content, poll that command until it exits, and only then finish."
  @http_created_status 201
  @http_accepted_status 202

  setup do
    model =
      System.get_env("LIVE_LLM_MODEL") ||
        flunk("LIVE_LLM_MODEL is required for the explicitly-run live provider smoke test")

    previous_adapter = Application.get_env(:kodo, :llm_adapter)
    Application.put_env(:kodo, :llm_adapter, Kodo.LLM.ReqLLM)

    on_exit(fn ->
      if previous_adapter,
        do: Application.put_env(:kodo, :llm_adapter, previous_adapter),
        else: Application.delete_env(:kodo, :llm_adapter)
    end)

    stack = Stack.start_stack!()
    workspace = Stack.fixture!()
    runner = Stack.start_runner!(stack.base_url, workspace)
    %{model: model, stack: stack, workspace: workspace, runner: runner}
  end

  test "a configured provider edits and verifies through the real runner", context do
    created =
      Stack.post!(
        context.stack.base_url,
        "/api/sessions",
        %{
          runner_id: context.runner.id,
          title: "Live provider greeting repair",
          model: context.model
        },
        @http_created_status
      )

    session_id = created["session"]["id"]
    on_exit(fn -> Stack.terminate_session!(session_id) end)
    Stack.subscribe_session!(session_id)

    assert %{"status" => "running"} =
             Stack.post!(
               context.stack.base_url,
               "/api/sessions/#{session_id}/messages",
               %{content: @prompt},
               @http_accepted_status
             )

    Stack.await_completed!(session_id, @live_session_timeout)
    replay = Stack.replay!(context.stack.base_url, session_id)

    assert replay["session"]["status"] == "completed"
    assert File.read!(Path.join(context.workspace, "greeting.txt")) == "hello\n"
    assert Enum.any?(replay["events"], &(&1["type"] == "assistant_message_completed"))

    sequences = Enum.map(replay["events"], & &1["sequence"])
    assert sequences == Enum.to_list(1..length(sequences))

    completed_tools =
      for %{"type" => "tool_completed", "payload" => payload} <- replay["events"],
          do: payload

    assert Enum.any?(completed_tools, &(&1["name"] == "apply_patch"))

    assert Enum.any?(completed_tools, fn payload ->
             payload["name"] in ["poll_command", "stop_command"] and
               match?(%{"exited" => %{"code" => 0}}, payload["output"]["status"])
           end)

    Stack.terminate_session!(session_id)
    assert {:ok, projection} = Sessions.active_state(session_id)
    assert projection.status == "completed"
  end
end
