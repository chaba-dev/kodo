defmodule Kodo.Agent.LoopTest do
  use Kodo.DataCase

  alias Kodo.Agent.Loop
  alias Kodo.Runners
  alias Kodo.Sessions

  import Kodo.AccountsFixtures

  setup do
    scope = user_scope_fixture()

    {:ok, runner} =
      Runners.register(scope, %{
        workspace_root: "/work/#{Ecto.UUID.generate()}",
        platform: "linux",
        architecture: "x86_64",
        runner_version: "0.1.0",
        protocol_version: 3,
        capabilities: []
      })

    {:ok, session} =
      Sessions.create_session(scope, %{
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

  test "counts interrupted provider attempts against the durable continuation budget", %{
    session: session
  } do
    {:ok, _event} =
      Sessions.append_event(session.id, "user_message", %{
        "role" => "user",
        "content" => "Fix it"
      })

    for continuation <- 1..2 do
      {:ok, _event} =
        Sessions.append_event(session.id, "model_invocation_started", %{
          "continuation" => continuation,
          "invocation_id" => Ecto.UUID.generate()
        })
    end

    assert {:error, :continuation_budget_exceeded} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets(max_continuations: 2)
             )

    assert Enum.count(
             Sessions.events_after(session.id),
             &(&1.type == "model_invocation_started")
           ) == 2
  end

  test "rejects duplicate provider tool-call ids before dispatch", %{session: session} do
    {:ok, _event} =
      Sessions.append_event(session.id, "user_message", %{
        "role" => "user",
        "content" => "duplicate tool ids"
      })

    assert {:error, :invalid_tool_call_ids} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets([])
             )

    refute Enum.any?(Sessions.events_after(session.id), &(&1.type == "tool_requested"))
  end

  test "records tool results for every call when one call fails", %{
    runner: runner,
    session: session
  } do
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    {:ok, _event} =
      Sessions.append_event(session.id, "user_message", %{
        "role" => "user",
        "content" => "multiple tools"
      })

    assert {:error, :tool_timeout} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets(tool_timeout: 0)
             )

    failures = Enum.filter(Sessions.events_after(session.id), &(&1.type == "tool_failed"))
    assert Enum.map(failures, & &1.payload["tool_call_id"]) == ["first", "second"]
  end

  defp budgets(overrides) do
    Keyword.merge(
      [max_continuations: 8, max_tokens: 1_000, model_timeout: 1_000, tool_timeout: 1_000],
      overrides
    )
  end
end
