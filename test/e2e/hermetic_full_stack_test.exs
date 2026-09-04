defmodule Kodo.E2E.HermeticFullStackTest do
  use Kodo.DataCase, async: false

  alias Kodo.Sessions
  alias Kodo.Integrations
  alias Kodo.Test.FullStackCase, as: Stack

  import Kodo.AccountsFixtures

  @moduletag timeout: 120_000

  @prompt "KODO_HERMETIC_FULL_STACK_FIX_GREETING"
  @model "openai:gpt-4o-mini"
  @required_tools ["apply_patch", "read_file", "git_diff"]
  @http_created_status 201
  @http_accepted_status 202

  setup do
    previous_adapter = Application.get_env(:kodo, :llm_adapter)
    Application.put_env(:kodo, :llm_adapter, Kodo.Test.FakeLLM)

    on_exit(fn ->
      if previous_adapter,
        do: Application.put_env(:kodo, :llm_adapter, previous_adapter),
        else: Application.delete_env(:kodo, :llm_adapter)
    end)

    stack = Stack.start_stack!()
    workspace = Stack.fixture!()
    user = user_fixture()
    scope = Kodo.Accounts.Scope.for_user(user)

    {:ok, _integration} =
      Integrations.connect(scope, "openai", "api_key", %{"api_key" => "e2e-test-key"})

    token = Kodo.Accounts.generate_user_agent_token(user)
    runner = Stack.start_runner!(stack.base_url, workspace, token)
    %{stack: stack, workspace: workspace, runner: runner, token: token}
  end

  test "real HTTP, control plane, and runner complete and reconstruct a coding turn", context do
    created =
      Stack.post!(
        context.stack.base_url,
        "/api/sessions",
        %{
          runner_id: context.runner.id,
          title: "Hermetic greeting repair",
          model: @model
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

    Stack.await_completed!(session_id)
    replay = Stack.replay!(context.stack.base_url, session_id, context.token)

    assert replay["session"]["status"] == "completed"
    assert File.read!(Path.join(context.workspace, "greeting.txt")) == "hello\n"

    events = replay["events"]
    sequences = Enum.map(events, & &1["sequence"])
    assert sequences == Enum.to_list(1..length(sequences))

    Enum.each(@required_tools, fn tool ->
      assert Enum.any?(events, fn event ->
               event["type"] == "tool_completed" and event["payload"]["name"] == tool
             end)
    end)

    diff =
      Enum.find(
        events,
        &(&1["type"] == "tool_completed" and &1["payload"]["name"] == "git_diff")
      )

    assert diff["payload"]["output"]["content"] =~ "+hello"

    Stack.terminate_session!(session_id)

    assert {:ok, projection} = Sessions.active_state(session_id)
    assert projection.status == "completed"

    assert List.last(projection.messages)["content"] ==
             "Greeting corrected and repository evidence verified."
  end
end
