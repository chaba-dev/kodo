defmodule Kodo.E2E.LiveProviderFullStackTest do
  use Kodo.DataCase, async: false

  alias Kodo.Sessions
  alias Kodo.Test.FullStackCase, as: Stack

  import Kodo.AccountsFixtures

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
    token = user_fixture() |> Kodo.Accounts.generate_user_agent_token()
    runner = Stack.start_runner!(stack.base_url, workspace, token)
    %{model: model, stack: stack, workspace: workspace, runner: runner, token: token}
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
        @http_created_status,
        context.token
      )

    session_id = created["session"]["id"]
    on_exit(fn -> Stack.terminate_session!(session_id) end)
    Stack.subscribe_session!(session_id)

    assert %{"status" => "running"} =
             Stack.post!(
               context.stack.base_url,
               "/api/sessions/#{session_id}/messages",
               %{content: @prompt},
               @http_accepted_status,
               context.token
             )

    Stack.await_completed!(session_id, @live_session_timeout)
    replay = Stack.replay!(context.stack.base_url, session_id, context.token)

    Stack.assert_live_outcome!(replay, context.workspace)

    Stack.terminate_session!(session_id)
    assert {:ok, projection} = Sessions.active_state(session_id)
    assert projection.status == "completed"
  end
end
