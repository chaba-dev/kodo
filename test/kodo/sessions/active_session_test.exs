defmodule Kodo.Sessions.ActiveSessionTest do
  use Kodo.DataCase

  alias Kodo.Runners
  alias Kodo.Cluster.Discovery
  alias Kodo.Cluster.InstanceManager
  alias Kodo.Cluster.Instances
  alias Kodo.Integrations
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

    {:ok, _integration} =
      Integrations.connect(scope, "openai", "api_key", %{"api_key" => "active-test-key"})

    {:ok, runner} =
      Runners.register(scope, %{
        workspace_root: "/work/#{Ecto.UUID.generate()}",
        platform: "linux",
        architecture: "x86_64",
        runner_version: "0.1.0",
        protocol_version: 5,
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

  test "does not start an unfenced coordinator when the enabled instance manager is absent", %{
    session: session
  } do
    put_instance_manager_enabled(true)

    assert {:error, :coordinator_unavailable} = Sessions.ensure_started(session.id)
    assert Registry.lookup(Kodo.SessionRegistry, session.id) == []
    assert Sessions.get_session!(session.id).owner_boot_id == nil
  end

  test "rejects coordinator startup for a different boot incarnation", %{session: session} do
    _manager = start_instance_manager!()

    assert {:error, :target_boot_mismatch} =
             Sessions.start_active_session_here(session.id, Ecto.UUID.generate())

    assert Registry.lookup(Kodo.SessionRegistry, session.id) == []
    assert Sessions.get_session!(session.id).owner_boot_id == nil
  end

  test "does not dispatch a selected boot to an incompatible replacement on the same node", %{
    session: session
  } do
    {:ok, old_boot} = Instances.register(instance_attrs(Atom.to_string(node())))
    {:ok, old_ownership} = Sessions.claim_ownership(session.id, old_boot.boot_id)

    _manager =
      start_instance_manager!(protocol_capabilities: ["session-ownership-v1"])

    assert {:error, :no_compatible_instance} = Sessions.ensure_started(session.id)
    assert Registry.lookup(Kodo.SessionRegistry, session.id) == []

    persisted = Sessions.get_session!(session.id)
    assert persisted.owner_boot_id == old_ownership.owner_boot_id
    assert persisted.ownership_epoch == old_ownership.epoch
  end

  test "normalizes a remote startup failure when the target supervisor is unavailable", %{
    session: session
  } do
    ensure_distributed_node!()
    {:ok, peer, peer_node} = :peer.start_link(%{name: :kodo_placement_peer})

    on_exit(fn -> stop_peer(peer) end)

    :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])
    _manager = start_instance_manager!(protocol_capabilities: ["session-ownership-v1"])
    {:ok, _remote} = Instances.register(instance_attrs(Atom.to_string(peer_node)))

    assert {:error, :coordinator_unavailable} = Sessions.ensure_started(session.id)
    assert Registry.lookup(Kodo.SessionRegistry, session.id) == []
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

  test "does not transiently restart when a task finishes after losing ownership", %{
    session: session
  } do
    assert {:ok, coordinator} = Sessions.ensure_started(session.id)
    assert :ok = ActiveSession.start_turn(coordinator, "ownership barrier")
    assert_receive {:model_dispatch_started, dispatch_pid}

    ownership = :sys.get_state(coordinator).ownership
    coordinator_ref = Process.monitor(coordinator)
    transfer = Task.async(fn -> Sessions.transfer_ownership(ownership, nil) end)
    transfer_ref = transfer.ref

    refute_receive {^transfer_ref, _result}
    send(dispatch_pid, :release_model_dispatch)

    assert {:ok, replacement} = Task.await(transfer)
    assert replacement.epoch > ownership.epoch
    assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, :normal}
  end

  test "drain waits for an in-flight model effect and yields at its next durable boundary", %{
    runner: runner,
    session: session
  } do
    manager = start_instance_manager!()
    {:ok, _runner_registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")
    assert :ok = Sessions.start_turn(session.id, "ownership barrier")
    assert_receive {:model_dispatch_started, dispatch_pid}

    drain = Task.async(fn -> InstanceManager.begin_drain(manager) end)
    drain_ref = drain.ref
    refute_receive {^drain_ref, _result}

    send(dispatch_pid, :release_model_dispatch)

    assert {:error, {:drain_incomplete, [:no_compatible_instance]}} = Task.await(drain)

    assert_receive {:tool_request, review_request}
    respond_to_tool(runner.id, review_request)

    assert_receive {:session_event,
                    %{type: "session_status_changed", payload: %{"status" => "completed"}}}

    events = Sessions.events_after(session.id)
    assert Enum.count(events, &(&1.type == "model_response")) == 1
    refute Enum.any?(events, &(&1.type == "session_failed"))
  end

  test "drain preserves one durable approval while no replacement is available", %{
    runner: runner,
    scope: scope,
    session: session
  } do
    manager = start_instance_manager!()
    {:ok, _runner_registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    {:ok, session} =
      session |> Ecto.Changeset.change(approval_policy: "safe") |> Kodo.Repo.update()

    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")

    assert :ok = Sessions.start_turn(session.id, "Fix it")

    assert_receive {:session_event,
                    %{type: "approval_requested", payload: %{"approval_id" => approval_id}}}

    assert {:error, {:drain_incomplete, [:no_compatible_instance]}} =
             InstanceManager.begin_drain(manager)

    assert Enum.count(Sessions.events_after(session.id), &(&1.type == "approval_requested")) == 1

    assert {:ok, {_resolved, _status}} =
             Sessions.resolve_approval(scope, session.id, approval_id, "approved")

    assert_receive {:tool_request, request}
    respond_to_tool(runner.id, request)

    assert_receive {:session_event,
                    %{type: "session_status_changed", payload: %{"status" => "completed"}}}

    assert Enum.count(Sessions.events_after(session.id), &(&1.type == "approval_requested")) == 1
  end

  test "drain timeout is one global deadline across all local coordinators" do
    timeout = 200
    coordinator_count = System.schedulers_online() * 2

    coordinators =
      for index <- 1..coordinator_count do
        {:ok, pid} =
          DynamicSupervisor.start_child(
            Kodo.SessionSupervisor,
            {Kodo.Test.BlockingDrainCoordinator, index}
          )

        pid
      end

    on_exit(fn ->
      Enum.each(coordinators, fn pid ->
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(Kodo.SessionSupervisor, pid)
      end)
    end)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, {:drain_incomplete, errors}} =
             Sessions.drain_owned_sessions(Ecto.UUID.generate(), timeout)

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert length(errors) == coordinator_count
    assert elapsed < timeout + 100
  end

  test "renews runner authority only after revalidating durable ownership", %{
    runner: runner,
    session: session
  } do
    _manager = start_instance_manager!()
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)
    assert {:ok, coordinator} = Sessions.ensure_started(session.id)
    ownership = :sys.get_state(coordinator).ownership

    expected = Kodo.RunnerProtocol.authority_lease(ownership)
    assert_receive {:authority_lease, ^expected}

    send(coordinator, :check_authority)
    assert_receive {:authority_lease, ^expected}
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

  test "persists a provider timeout as a terminal session failure", %{session: session} do
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")

    assert :ok = Sessions.start_turn(session.id, "provider timeout")

    assert_receive {:session_event,
                    %{type: "session_failed", payload: %{"reason" => ":provider_timeout"}}}

    assert_receive {:session_event,
                    %{type: "session_status_changed", payload: %{"status" => "failed"}}}

    assert Sessions.get_session!(session.id).status == "failed"
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

  test "reconstructs a durable approval wait and dispatches its request", %{
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

    {:ok, replay} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Replayed approval",
        model: session.model,
        approval_policy: "safe"
      })

    session.id
    |> Sessions.events_after()
    |> Enum.drop(1)
    |> Enum.each(fn event ->
      assert {:ok, _event} =
               Sessions.append_event(replay.id, event.type, event.payload,
                 source: event.source,
                 version: event.version,
                 parent_id: event.parent_id
               )
    end)

    replay
    |> Ecto.Changeset.change(status: "awaiting_approval")
    |> Kodo.Repo.update!()

    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{replay.id}")

    assert {:ok, {_resolved, _status}} =
             Sessions.resolve_approval(scope, replay.id, approval_id, "approved")

    assert {:ok, _coordinator} = Sessions.ensure_started(replay.id)
    assert_receive {:tool_request, %{"request_id" => ^request_id} = request}
    respond_to_tool(runner.id, request)

    assert_receive {:session_event,
                    %{type: "session_status_changed", payload: %{"status" => "completed"}}}

    assert Enum.count(Sessions.events_after(replay.id), &(&1.type == "approval_requested")) == 1
    assert Enum.count(Sessions.events_after(replay.id), &(&1.type == "tool_requested")) == 2
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
      [{pid, _value}] = Registry.lookup(Kodo.SessionRegistry, session.id)
      ref = Process.monitor(pid)
      respond_to_tool(runner.id, request)

      assert_receive {:session_event,
                      %{type: "session_status_changed", payload: %{"status" => "completed"}}}

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    events = Sessions.events_after(session.id)
    assert Enum.count(events, &(&1.type == "user_message")) == 2
    assert Enum.count(events, &(&1.type == "model_response")) == 4
  end

  test "reads terminal state without restarting its coordinator", %{
    runner: runner,
    session: session
  } do
    {:ok, _runner_registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")
    assert :ok = Sessions.start_turn(session.id, "token budget")
    [{pid, _value}] = Registry.lookup(Kodo.SessionRegistry, session.id)
    ref = Process.monitor(pid)

    assert_receive {:tool_request, review_request}
    respond_to_tool(runner.id, review_request)

    assert_receive {:session_event,
                    %{type: "session_status_changed", payload: %{"status" => "completed"}}}

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    _ = :sys.get_state(Kodo.SessionRegistry)

    assert {:ok, %{status: "completed"}} = Sessions.active_state(session.id)
    assert Registry.lookup(Kodo.SessionRegistry, session.id) == []
  end

  test "a state read stops a terminal coordinator created during a storage race", %{
    session: session
  } do
    assert {:ok, _event} = Sessions.set_status(session.id, "completed")
    assert {:ok, coordinator} = Sessions.ensure_started(session.id)
    coordinator_ref = Process.monitor(coordinator)

    assert {:ok, %{status: "completed"}} = Sessions.active_state(session.id)
    assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, :normal}
  end

  test "recovery stops a coordinator when an active discovery row became terminal", %{
    session: session
  } do
    assert {:ok, _event} = Sessions.set_status(session.id, "running")
    assert Enum.any?(Sessions.list_active_sessions(), &(&1.id == session.id))
    assert {:ok, _event} = Sessions.set_status(session.id, "completed")
    assert {:ok, coordinator} = Sessions.reconcile_started(session.id)
    coordinator_ref = Process.monitor(coordinator)

    assert :ok = ActiveSession.stop_if_terminal(coordinator)
    assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, :normal}
  end

  test "a follow-up updates terminal projection before a queued recovery stop", %{
    session: session
  } do
    assert {:ok, _event} = Sessions.set_status(session.id, "completed")
    assert {:ok, coordinator} = Sessions.ensure_started(session.id)
    coordinator_ref = Process.monitor(coordinator)
    :ok = :sys.suspend(coordinator)

    on_exit(fn ->
      try do
        :sys.resume(coordinator)
      catch
        :exit, _reason -> :ok
      end
    end)

    follow_up =
      Task.async(fn -> ActiveSession.start_turn(coordinator, "ownership barrier") end)

    await_queued_call(coordinator, fn
      {:start_turn, "ownership barrier", nil} -> true
      _message -> false
    end)

    recovery_stop = Task.async(fn -> ActiveSession.stop_if_terminal(coordinator) end)
    await_queued_call(coordinator, &(&1 == :stop_if_terminal))
    :ok = :sys.resume(coordinator)

    assert :ok = Task.await(follow_up)
    assert :ok = Task.await(recovery_stop)
    assert_receive {:model_dispatch_started, dispatch_pid}
    refute_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason}

    send(dispatch_pid, :release_model_dispatch)
  end

  test "retries a follow-up that races with a terminal coordinator exit", %{session: session} do
    {:ok, exiting} =
      DynamicSupervisor.start_child(
        Kodo.SessionSupervisor,
        {Kodo.Test.ExitingCoordinator, {session.id, self()}}
      )

    assert_receive {:exiting_coordinator_ready, ^exiting}

    assert :ok = Sessions.start_turn(session.id, "ownership barrier", Ecto.UUID.generate())
    assert_receive {:exiting_coordinator_called, ^exiting}
    assert_receive {:model_dispatch_started, dispatch_pid}

    assert Enum.any?(Sessions.events_after(session.id), fn event ->
             event.type == "user_message" and event.payload["content"] == "ownership barrier"
           end)

    send(dispatch_pid, :release_model_dispatch)
  end

  test "reconstructs terminal state when a remote coordinator disappears", %{session: session} do
    assert {:ok, _event} = Sessions.set_status(session.id, "completed")
    ensure_distributed_node!()
    {:ok, peer, peer_node} = :peer.start_link(%{name: :kodo_terminal_state_peer})

    on_exit(fn -> stop_peer(peer) end)

    :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])
    {:ok, _scope} = :erpc.call(peer_node, :pg, :start, [Discovery.scope()])

    {monitor_ref, _members} =
      :pg.monitor(Discovery.scope(), Discovery.group(:session, session.id))

    remote_pid =
      :erpc.call(peer_node, Kodo.Test.RemoteCoordinator, :start, [
        self(),
        Discovery.scope(),
        session.id
      ])

    assert_receive {^monitor_ref, :join, {:session, session_id}, [^remote_pid]}
    assert session_id == session.id
    call = Task.async(fn -> Sessions.active_state(session.id) end)
    assert_receive {:remote_call_received, ^remote_pid}
    :ok = :peer.stop(peer)

    assert {:ok, %{status: "completed"}} = Task.await(call)
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

  test "dispatches when discovery converges without another connection notification", %{
    runner: runner,
    session: session
  } do
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")
    assert :ok = Sessions.start_turn(session.id, "Fix it")

    assert_receive {:session_event,
                    %{type: "tool_started", payload: %{"request_id" => request_id}}}

    :ok = Discovery.join_runner(runner.id)
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

  test "cancellation interrupts a durable tool response wait", %{
    runner: runner,
    session: session
  } do
    {:ok, _runner_registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")
    assert :ok = Sessions.start_turn(session.id, "Fix it")
    assert_receive {:tool_request, _request}

    [{coordinator, _value}] = Registry.lookup(Kodo.SessionRegistry, session.id)
    ownership = :sys.get_state(coordinator).ownership
    assert :ok = Sessions.dispatch_if_owner(ownership, fn -> :ok end)

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

  test "startup recovery retries a session when placement is temporarily unavailable", %{
    session: session
  } do
    put_instance_manager_enabled(true)

    {:ok, _event} =
      Sessions.append_event(session.id, "user_message", %{
        "role" => "user",
        "content" => "wait"
      })

    {:ok, _status} = Sessions.set_status(session.id, "running")

    recovery = start_supervised!({Recovery, name: nil, coordinated: false})
    assert Registry.lookup(Kodo.SessionRegistry, session.id) == []

    _manager = start_instance_manager!()
    send(recovery, :retry)
    _ = :sys.get_state(recovery)
    assert_receive :fake_llm_waiting, 1_000
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

    assert_receive :fake_llm_waiting
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
    response =
      case request["request"]["tool"] do
        "git_diff" -> %{"result" => "output", "content" => "clean diff", "truncated" => false}
        _other -> %{"result" => "files_changed", "paths" => []}
      end

    Phoenix.PubSub.broadcast(
      Kodo.PubSub,
      "runner_responses:#{runner_id}",
      {:runner_tool_response, runner_id,
       %{
         "protocol_version" => 5,
         "request_id" => request["request_id"],
         "status" => "success",
         "response" => response
       }}
    )

    if request["request"]["tool"] != "git_diff" do
      assert_receive {:tool_request, next_request}
      respond_to_tool(runner_id, next_request)
    end
  end

  defp start_instance_manager!(overrides \\ []) do
    start_supervised!({
      InstanceManager,
      enabled: true,
      boot_id: Ecto.UUID.generate(),
      node_name: Atom.to_string(node()),
      artifact_revision: "test-revision",
      deployment_generation: 1,
      capacity: 1,
      protocol_capabilities:
        Keyword.get(
          overrides,
          :protocol_capabilities,
          [
            "session-events-v1",
            "session-ownership-v1",
            "session-placement-v1",
            "session-rehoming-v1"
          ]
        ),
      heartbeat_interval: :infinity
    })
  end

  defp put_instance_manager_enabled(enabled) do
    previous = Application.fetch_env!(:kodo, InstanceManager)
    Application.put_env(:kodo, InstanceManager, Keyword.put(previous, :enabled, enabled))
    on_exit(fn -> Application.put_env(:kodo, InstanceManager, previous) end)
  end

  defp ensure_distributed_node! do
    if node() == :nonode@nohost do
      {_output, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _pid} = :net_kernel.start([:kodo_placement_test, :shortnames])
    end
  end

  defp stop_peer(peer) do
    try do
      :peer.stop(peer)
    catch
      :exit, _reason -> :ok
    end
  end

  defp await_queued_call(coordinator, matches?) do
    {:messages, messages} = Process.info(coordinator, :messages)

    if Enum.any?(messages, fn
         {:"$gen_call", _from, request} -> matches?.(request)
         _message -> false
       end) do
      :ok
    else
      await_queued_call(coordinator, matches?)
    end
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
      protocol_capabilities: [
        "session-events-v1",
        "session-ownership-v1",
        "session-placement-v1",
        "session-rehoming-v1"
      ]
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:kodo, key)
  defp restore_env(key, value), do: Application.put_env(:kodo, key, value)
end
