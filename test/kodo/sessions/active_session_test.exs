defmodule Kodo.Sessions.ActiveSessionTest do
  use Kodo.DataCase

  alias Kodo.Runners
  alias Kodo.Cluster.InstanceManager
  alias Kodo.Cluster.Instances
  alias Kodo.Sessions
  alias Kodo.Sessions.ActiveSession
  alias Kodo.Sessions.Recovery

  import Kodo.AccountsFixtures

  setup do
    previous_adapter = Application.get_env(:kodo, :llm_adapter)
    previous_test_pid = Application.get_env(:kodo, :fake_llm_test_pid)
    Application.put_env(:kodo, :llm_adapter, Kodo.Test.FakeLLM)
    Application.put_env(:kodo, :fake_llm_test_pid, self())

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
        title: "Recover me",
        model: "openai:gpt-4o-mini"
      })

    on_exit(fn ->
      case Registry.lookup(Kodo.SessionRegistry, session.id) do
        [{pid, _value}] -> DynamicSupervisor.terminate_child(Kodo.SessionSupervisor, pid)
        [] -> :ok
      end

      restore_env(:llm_adapter, previous_adapter)
      restore_env(:fake_llm_test_pid, previous_test_pid)
    end)

    %{runner: runner, scope: scope, session: session}
  end

  test "ensures only one supervised process per session", %{session: session} do
    assert {:ok, first} = Sessions.ensure_started(session.id)
    assert {:ok, second} = Sessions.ensure_started(session.id)
    assert first == second
  end

  test "stops when its durable ownership epoch is replaced", %{session: session} do
    _manager = start_instance_manager!()
    {:ok, replacement} = Instances.register(instance_attrs("kodo@replacement"))
    assert {:ok, coordinator} = Sessions.ensure_started(session.id)
    ownership = :sys.get_state(coordinator).ownership

    assert {:ok, _replacement_ownership} =
             Sessions.transfer_ownership(ownership, replacement.boot_id)

    ref = Process.monitor(coordinator)
    send(coordinator, :check_authority)

    assert_receive {:DOWN, ^ref, :process, ^coordinator, :normal}
  end

  test "stops when the process maintaining authoritative liveness exits", %{session: session} do
    manager = start_instance_manager!()
    assert {:ok, coordinator} = Sessions.ensure_started(session.id)
    assert :ok = ActiveSession.start_turn(coordinator, "wait")
    assert_receive :fake_llm_waiting

    task = :sys.get_state(coordinator).task.pid
    coordinator_ref = Process.monitor(coordinator)
    manager_ref = Process.monitor(manager)
    task_ref = Process.monitor(task)

    assert :ok = stop_supervised(InstanceManager)

    assert_receive {:DOWN, ^manager_ref, :process, ^manager, :shutdown}
    assert_receive {:DOWN, ^task_ref, :process, ^task, :killed}

    assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, :normal}
  end

  test "reconciles a repeated turn request while its task is active", %{session: session} do
    request_id = Ecto.UUID.generate()
    assert {:ok, pid} = Sessions.ensure_started(session.id)
    assert :ok = ActiveSession.start_turn(pid, "wait", request_id)
    assert_receive :fake_llm_waiting
    assert :ok = ActiveSession.start_turn(pid, "wait", request_id)
    assert Enum.count(Sessions.events_after(session.id), &(&1.type == "user_message")) == 1
    assert :ok = ActiveSession.cancel(pid)
  end

  test "concurrent cancellation retries reconcile from durable status", %{
    session: session,
    scope: scope
  } do
    assert :ok = Sessions.start_turn(session.id, "wait")
    assert_receive :fake_llm_waiting

    results =
      1..2
      |> Task.async_stream(fn _ -> Sessions.cancel(scope, session.id) end,
        max_concurrency: 2,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results == [:ok, :ok]
    assert Sessions.get_session!(session.id).status == "cancelled"
  end

  test "reconstructs state after its process is discarded", %{session: session} do
    {:ok, _event} =
      Sessions.append_event(session.id, "user_message", %{
        "role" => "user",
        "content" => "Fix the bug"
      })

    {:ok, first} = Sessions.ensure_started(session.id)
    assert :ok = DynamicSupervisor.terminate_child(Kodo.SessionSupervisor, first)

    assert {:ok, second} = Sessions.ensure_started(session.id)

    projection = ActiveSession.state(second)
    assert projection.title == "Recover me"
    assert projection.messages == [%{"role" => "user", "content" => "Fix the bug"}]
    assert projection.last_sequence == 2
  end

  test "restarts its coordinator and resumes an interrupted provider request", %{session: session} do
    assert :ok = Sessions.start_turn(session.id, "wait")
    assert_receive :fake_llm_waiting, 1_000

    [{first, _value}] = Registry.lookup(Kodo.SessionRegistry, session.id)
    crash(first)

    assert_receive :fake_llm_waiting, 1_000
    [{second, _value}] = Registry.lookup(Kodo.SessionRegistry, session.id)
    refute first == second
    assert :ok = Sessions.cancel(session.id)
  end

  test "reconstructs an approval wait and dispatches its durable request after restart", %{
    runner: runner,
    scope: scope,
    session: session
  } do
    {:ok, _runner_registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    {:ok, session} =
      session |> Ecto.Changeset.change(approval_policy: "safe") |> Kodo.Repo.update()

    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")

    assert :ok = Sessions.start_turn(session.id, "Fix it")

    assert_receive {:session_event,
                    %{type: "tool_requested", payload: %{"request_id" => request_id}}}

    assert_receive {:session_event,
                    %{type: "approval_requested", payload: %{"approval_id" => approval_id}}}

    [{first, _value}] = Registry.lookup(Kodo.SessionRegistry, session.id)
    assert :ok = DynamicSupervisor.terminate_child(Kodo.SessionSupervisor, first)

    assert {:ok, {_resolved, _status}} =
             Sessions.resolve_approval(scope, session.id, approval_id, "approved")

    assert {:ok, second} = Sessions.ensure_started(session.id)
    refute first == second
    assert_receive {:tool_request, %{"request_id" => ^request_id} = request}
    respond_to_tool(runner.id, request)

    assert_receive {:session_event,
                    %{type: "session_status_changed", payload: %{"status" => "completed"}}}

    assert Enum.count(Sessions.events_after(session.id), &(&1.type == "approval_requested")) == 1
    assert Enum.count(Sessions.events_after(session.id), &(&1.type == "tool_requested")) == 1
  end

  test "redispatches the same request id after a crash during tool execution", %{
    runner: runner,
    session: session
  } do
    {:ok, _runner_registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")
    assert :ok = Sessions.start_turn(session.id, "Fix it")
    assert_receive {:tool_request, %{"request_id" => request_id}}
    _ = Sessions.get_session!(session.id)

    [{first, _value}] = Registry.lookup(Kodo.SessionRegistry, session.id)
    crash(first)

    assert [{second, _value}] = Registry.lookup(Kodo.SessionRegistry, session.id)
    refute first == second
    assert_receive {:tool_request, %{"request_id" => ^request_id} = replayed}
    respond_to_tool(runner.id, replayed)

    assert_receive {:session_event,
                    %{type: "session_status_changed", payload: %{"status" => "completed"}}}
  end

  test "starts a new model turn after a prior turn completed", %{
    runner: runner,
    session: session
  } do
    {:ok, _runner_registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")

    for message <- ["First fix", "Second fix"] do
      assert :ok = Sessions.start_turn(session.id, message)
      assert_receive {:tool_request, request}
      respond_to_tool(runner.id, request)

      assert_receive {:session_event,
                      %{type: "session_status_changed", payload: %{"status" => "completed"}}}

      [{pid, _value}] = Registry.lookup(Kodo.SessionRegistry, session.id)
      _ = :sys.get_state(pid)
    end

    events = Sessions.events_after(session.id)
    assert Enum.count(events, &(&1.type == "user_message")) == 2
    assert Enum.count(events, &(&1.type == "model_response")) == 4
  end

  test "redispatches a durable request when an offline runner reconnects", %{
    runner: runner,
    session: session
  } do
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")
    assert :ok = Sessions.start_turn(session.id, "Fix it")

    assert_receive {:session_event,
                    %{type: "tool_started", payload: %{"request_id" => request_id}}}

    {:ok, _runner_registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)
    assert {:ok, _runner} = Runners.connected(runner)
    assert_receive {:tool_request, %{"request_id" => ^request_id} = request}
    respond_to_tool(runner.id, request)

    assert_receive {:session_event,
                    %{type: "session_status_changed", payload: %{"status" => "completed"}}}
  end

  test "redispatches after a runner disconnects while executing a request", %{
    runner: runner,
    session: session
  } do
    {:ok, _runner_registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")
    assert :ok = Sessions.start_turn(session.id, "Fix it")
    assert_receive {:tool_request, %{"request_id" => request_id}}

    Registry.unregister(Kodo.RunnerRegistry, runner.id)
    {:ok, _runner_registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)
    assert {:ok, _runner} = Runners.connected(runner)
    assert_receive {:tool_request, %{"request_id" => ^request_id} = replayed}
    respond_to_tool(runner.id, replayed)

    assert_receive {:session_event,
                    %{type: "session_status_changed", payload: %{"status" => "completed"}}}
  end

  test "cancellation interrupts a durable offline-runner wait", %{session: session} do
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")
    assert :ok = Sessions.start_turn(session.id, "Fix it")
    assert_receive {:session_event, %{type: "tool_started"}}

    assert :ok = Sessions.cancel(session.id)
    assert Sessions.get_session!(session.id).status == "cancelled"
  end

  test "startup recovery starts every durable active session", %{session: session} do
    {:ok, _event} =
      Sessions.append_event(session.id, "user_message", %{
        "role" => "user",
        "content" => "wait"
      })

    {:ok, _status} = Sessions.set_status(session.id, "running")
    Recovery.recover_active_sessions()

    assert_receive :fake_llm_waiting
    assert [{pid, _value}] = Registry.lookup(Kodo.SessionRegistry, session.id)
    assert :ok = ActiveSession.cancel(pid)
  end

  test "supervision-tree restart reconstructs active sessions before serving again", %{
    session: session
  } do
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")
    assert :ok = Sessions.start_turn(session.id, "wait")
    assert_receive :fake_llm_waiting

    assert_receive {:session_event,
                    %{
                      type: "model_invocation_started",
                      payload: %{"invocation_id" => first_invocation_id}
                    }}

    supervisor = Process.whereis(Kodo.SessionSupervisor)
    recovery = Process.whereis(Kodo.Sessions.Recovery)
    ref = Process.monitor(supervisor)
    Process.exit(supervisor, :kill)
    assert_receive {:DOWN, ^ref, :process, ^supervisor, :killed}
    _ = :sys.get_state(Kodo.Supervisor)

    refute Process.whereis(Kodo.SessionSupervisor) == supervisor
    refute Process.whereis(Kodo.Sessions.Recovery) == recovery

    assert_receive {:session_event,
                    %{
                      type: "model_invocation_started",
                      payload: %{"invocation_id" => second_invocation_id}
                    }},
                   3_000

    refute first_invocation_id == second_invocation_id
    assert [{pid, _value}] = Registry.lookup(Kodo.SessionRegistry, session.id)
    assert :ok = ActiveSession.cancel(pid)
  end

  test "reloads committed events in sequence when notifications arrive out of order", %{
    session: session
  } do
    {:ok, pid} = Sessions.ensure_started(session.id)
    ownership = :sys.get_state(pid).ownership

    {:ok, second} =
      Sessions.append_event(session.id, "user_message", %{"content" => "one"},
        ownership: ownership
      )

    {:ok, third} =
      Sessions.append_event(session.id, "user_message", %{"content" => "two"},
        ownership: ownership
      )

    send(pid, {:session_event, third})
    _ = :sys.get_state(pid)
    send(pid, {:session_event, second})
    _ = :sys.get_state(pid)

    projection = ActiveSession.state(pid)
    assert Enum.map(projection.messages, & &1["content"]) == ["one", "two"]
    assert projection.last_sequence == 3
  end

  defp crash(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    _ = :sys.get_state(Kodo.SessionSupervisor)
  end

  defp respond_to_tool(runner_id, request) do
    Phoenix.PubSub.broadcast(
      Kodo.PubSub,
      "runner_responses:#{runner_id}",
      {:runner_tool_response, runner_id,
       %{
         "protocol_version" => 3,
         "request_id" => request["request_id"],
         "status" => "success",
         "response" => %{"result" => "files_changed", "paths" => []}
       }}
    )
  end

  defp start_instance_manager! do
    start_supervised!({
      InstanceManager,
      enabled: true,
      boot_id: Ecto.UUID.generate(),
      node_name: "kodo@authority",
      artifact_revision: "test-revision",
      deployment_generation: 1,
      capacity: 1,
      protocol_capabilities: ["session-events-v1", "session-ownership-v1"],
      heartbeat_interval: :infinity
    })
  end

  defp instance_attrs(node_name) do
    %{
      boot_id: Ecto.UUID.generate(),
      node_name: node_name,
      artifact_revision: "test-revision",
      deployment_generation: 1,
      ready: true,
      draining: false,
      capacity: 1,
      protocol_capabilities: ["session-events-v1", "session-ownership-v1"]
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:kodo, key)
  defp restore_env(key, value), do: Application.put_env(:kodo, key, value)
end
