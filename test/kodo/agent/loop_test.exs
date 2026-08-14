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
        protocol_version: 4,
        capabilities: []
      })

    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Budgeted turn",
        model: "test:model"
      })

    {:ok, ownership} = Sessions.claim_ownership(session.id, nil)

    %{runner: runner, session: session, ownership: ownership}
  end

  test "stops before accepting a response that exceeds the token budget", %{
    session: session,
    ownership: ownership
  } do
    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{
          "role" => "user",
          "content" => "token budget"
        },
        ownership: ownership
      )

    assert {:error, :token_budget_exceeded} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets(max_tokens: 100),
               ownership: ownership
             )
  end

  test "does not dispatch a model effect after its ownership epoch is replaced", %{
    session: session,
    ownership: ownership
  } do
    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "token budget"},
        ownership: ownership
      )

    assert {:ok, replacement} = Sessions.claim_ownership(session.id, nil)
    assert replacement.epoch > ownership.epoch

    assert {:error, :stale_ownership} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets([]),
               ownership: ownership
             )

    refute Enum.any?(Sessions.events_after(session.id), &(&1.type == "model_invocation_started"))
  end

  test "ownership transfer waits for an in-flight model dispatch boundary", %{
    session: session,
    ownership: ownership
  } do
    previous_test_pid = Application.get_env(:kodo, :fake_llm_test_pid)
    Application.put_env(:kodo, :fake_llm_test_pid, self())

    on_exit(fn -> restore_env(:fake_llm_test_pid, previous_test_pid) end)

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "ownership barrier"},
        ownership: ownership
      )

    loop =
      Task.async(fn ->
        Loop.run(session.id,
          adapter: Kodo.Test.FakeLLM,
          budgets: budgets([]),
          ownership: ownership
        )
      end)

    assert_receive {:model_dispatch_started, dispatch_pid}

    transfer =
      Task.async(fn ->
        Sessions.transfer_ownership(ownership, nil)
      end)

    transfer_before_release =
      receive do
        {ref, result} when ref == transfer.ref -> result
      after
        100 -> :blocked
      end

    send(dispatch_pid, :release_model_dispatch)

    assert transfer_before_release == :blocked
    assert {:ok, replacement} = Task.await(transfer)
    assert replacement.epoch > ownership.epoch
    assert {:error, :stale_ownership} = Task.await(loop)
  end

  test "records a typed tool timeout", %{
    runner: runner,
    session: session,
    ownership: ownership
  } do
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{
          "role" => "user",
          "content" => "Fix it"
        },
        ownership: ownership
      )

    assert {:error, :tool_timeout} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets(tool_timeout: 0),
               ownership: ownership
             )

    assert Enum.any?(Sessions.events_after(session.id), fn event ->
             event.type == "tool_failed" and event.payload["error"] == ":tool_timeout"
           end)
  end

  test "counts interrupted provider attempts against the durable continuation budget", %{
    session: session,
    ownership: ownership
  } do
    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{
          "role" => "user",
          "content" => "Fix it"
        },
        ownership: ownership
      )

    for continuation <- 1..2 do
      {:ok, _event} =
        Sessions.append_event(
          session.id,
          "model_invocation_started",
          %{
            "continuation" => continuation,
            "invocation_id" => Ecto.UUID.generate()
          },
          ownership: ownership
        )
    end

    assert {:error, :continuation_budget_exceeded} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets(max_continuations: 2),
               ownership: ownership
             )

    assert Enum.count(
             Sessions.events_after(session.id),
             &(&1.type == "model_invocation_started")
           ) == 2
  end

  test "rejects duplicate provider tool-call ids before dispatch", %{
    session: session,
    ownership: ownership
  } do
    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{
          "role" => "user",
          "content" => "duplicate tool ids"
        },
        ownership: ownership
      )

    assert {:error, :invalid_tool_call_ids} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets([]),
               ownership: ownership
             )

    refute Enum.any?(Sessions.events_after(session.id), &(&1.type == "tool_requested"))
  end

  test "records tool results for every call when one call fails", %{
    runner: runner,
    session: session,
    ownership: ownership
  } do
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{
          "role" => "user",
          "content" => "multiple tools"
        },
        ownership: ownership
      )

    assert {:error, :tool_timeout} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets(tool_timeout: 0),
               ownership: ownership
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

  defp restore_env(key, nil), do: Application.delete_env(:kodo, key)
  defp restore_env(key, value), do: Application.put_env(:kodo, key, value)
end
