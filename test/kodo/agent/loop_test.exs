defmodule Kodo.Agent.LoopTest do
  use Kodo.DataCase

  alias Kodo.Agent.Loop
  alias Kodo.Runners
  alias Kodo.Sessions

  import Kodo.AccountsFixtures

  setup do
    {:ok, runner} =
      Runners.register(%{
        workspace_root: "/work/#{Ecto.UUID.generate()}",
        platform: "linux",
        architecture: "x86_64",
        runner_version: "0.1.0",
        protocol_version: 3,
        capabilities: []
      })

    {:ok, session} =
      Sessions.create_session(user_scope_fixture(), %{
        runner_id: runner.id,
        title: "Budgeted turn",
        model: "test:model"
      })

    %{runner: runner, session: session}
  end

  test "stops before accepting a response that exceeds the token budget", %{session: session} do
    {:ok, _event} =
      Sessions.append_event(session.id, "user_message", %{
        "role" => "user",
        "content" => "token budget"
      })

    assert {:error, :token_budget_exceeded} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets(max_tokens: 100)
             )
  end

  test "records a typed tool timeout", %{runner: runner, session: session} do
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    {:ok, _event} =
      Sessions.append_event(session.id, "user_message", %{
        "role" => "user",
        "content" => "Fix it"
      })

    assert {:error, :tool_timeout} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets(tool_timeout: 0)
             )

    assert Enum.any?(Sessions.events_after(session.id), fn event ->
             event.type == "tool_failed" and event.payload["error"] == ":tool_timeout"
           end)
  end

  defp budgets(overrides) do
    Keyword.merge(
      [max_continuations: 8, max_tokens: 1_000, model_timeout: 1_000, tool_timeout: 1_000],
      overrides
    )
  end
end
