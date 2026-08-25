defmodule Kodo.Cluster.DistributedHandoffTest do
  use ExUnit.Case, async: false

  alias Kodo.Accounts.Scope
  alias Kodo.Cluster.Discovery
  alias Kodo.Cluster.InstanceManager
  alias Kodo.Cluster.Instances
  alias Kodo.Cluster.Placement
  alias Kodo.Repo
  alias Kodo.Runners
  alias Kodo.Sessions

  import Ecto.Query
  import Kodo.AccountsFixtures

  @capabilities [
    "session-events-v1",
    "session-ownership-v1",
    "session-placement-v1",
    "session-rehoming-v1"
  ]

  setup do
    ensure_distributed_node!()
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    previous_adapter = Application.get_env(:kodo, :llm_adapter)
    previous_test_pid = Application.get_env(:kodo, :fake_llm_test_pid)
    Application.put_env(:kodo, :llm_adapter, Kodo.Test.FakeLLM)
    Application.put_env(:kodo, :fake_llm_test_pid, self())

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
      restore_env(:llm_adapter, previous_adapter)
      restore_env(:fake_llm_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "two BEAM nodes fence competing claims and hand a session forward and back" do
    {:ok, peer, peer_node} = :peer.start_link(%{name: :kodo_handoff_peer})
    :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])

    source_manager =
      start_instance_manager!("old-artifact", 10,
        protocol_capabilities: Enum.reject(@capabilities, &(&1 == "session-rehoming-v1"))
      )

    source = InstanceManager.current_instance(source_manager)
    remote_supervisor = start_remote_control_plane!(peer_node, "current-artifact", 11)
    target = :erpc.call(peer_node, InstanceManager, :current_instance, [])

    on_exit(fn ->
      stop_peer(peer)
      cleanup_cluster_rows()
    end)

    assert_competing_claims_are_fenced(source, target, peer_node)

    user = user_fixture()
    scope = Scope.for_user(user)

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
        title: "Distributed handoff",
        model: "test:model",
        approval_policy: "safe"
      })

    :ok = Discovery.join_runner(runner.id)
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")
    assert {:ok, _ownership} = Sessions.claim_ownership(session.id, source.boot_id)

    assert :ok = Sessions.start_turn(session.id, "forward")
    first_approval = receive_approval_id()

    assert {:ok, draining_source} = Instances.begin_drain(source)
    assert draining_source.boot_id == source.boot_id
    :ok = :erpc.call(peer_node, Process, :send, [Kodo.Sessions.Recovery, :retry, []])
    assert_eventually_owned(session.id, target.boot_id, peer_node)
    assert Enum.any?(Discovery.members(:session, session.id), &(node(&1) == peer_node))

    complete_approved_tool(scope, session, runner, first_approval)

    assert :ok = stop_supervised(InstanceManager)
    rollback_manager = start_instance_manager!("old-artifact", 10)
    rollback_target = InstanceManager.current_instance(rollback_manager)

    assert {:ok, _override} =
             Placement.create_rollback_override(scope, %{
               "artifact_revision" => "old-artifact",
               "reason" => "Distributed rollback test",
               "expires_in_seconds" => 300
             })

    assert :ok = Sessions.start_turn(session.id, "rollback")
    second_approval = receive_approval_id()

    assert {:ok, draining_target} =
             :erpc.call(peer_node, InstanceManager, :begin_drain, [])

    assert draining_target.boot_id == target.boot_id
    assert Sessions.get_session!(session.id).owner_boot_id == rollback_target.boot_id
    assert Enum.any?(Discovery.members(:session, session.id), &(node(&1) == node()))

    complete_approved_tool(scope, session, runner, second_approval)

    events = Sessions.events_after(session.id)
    assert Enum.count(events, &(&1.type == "approval_requested")) == 2
    assert Enum.count(events, &(&1.type == "tool_requested")) == 4
    assert Enum.count(events, &(&1.type == "tool_completed")) == 4

    assert :ok = :erpc.call(peer_node, Supervisor, :stop, [remote_supervisor])
    :ok = Discovery.subscribe()
    assert :ok = :peer.stop(peer)
    assert_receive {:cluster_node, :down, ^peer_node, _info}, 5_000
  end

  test "node loss replays one durable mutation without executing it twice" do
    {:ok, peer, peer_node} = :peer.start_link(%{name: :kodo_node_loss_peer})
    :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])

    _fallback_manager = start_instance_manager!("fallback-artifact", 10)
    _remote_supervisor = start_remote_control_plane!(peer_node, "current-artifact", 11)
    target = :erpc.call(peer_node, InstanceManager, :current_instance, [])

    on_exit(fn ->
      stop_peer(peer)
      cleanup_cluster_rows()
    end)

    user = user_fixture()
    scope = Scope.for_user(user)

    {:ok, runner} =
      Runners.register(scope, %{
        workspace_root: "/work/#{Ecto.UUID.generate()}",
        platform: "linux",
        architecture: "x86_64",
        runner_version: "0.1.0",
        protocol_version: 4,
        capabilities: []
      })

    runner_pid = start_supervised!({Kodo.Test.DurableTestRunner, {runner.id, self()}})

    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Node-loss replay",
        model: "test:model",
        approval_policy: "safe"
      })

    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")
    assert {:ok, _ownership} = Sessions.claim_ownership(session.id, target.boot_id)
    assert :ok = Sessions.start_turn(session.id, "node loss")
    approval_id = receive_approval_id()

    assert {:ok, {_resolved, _status}} =
             Sessions.resolve_approval(scope, session.id, approval_id, "approved")

    assert_receive {:tool_execution_started, request_id}, 5_000
    refute_receive {:tool_execution_started, ^request_id}

    :ok = Discovery.subscribe()
    assert :ok = :peer.stop(peer)
    assert_receive {:cluster_node, :down, ^peer_node, _info}, 5_000

    Kodo.Cluster.Instance
    |> where([instance], instance.boot_id == ^target.boot_id)
    |> Repo.update_all(set: [last_seen_at: DateTime.add(DateTime.utc_now(), -120, :second)])

    :ok = Kodo.Sessions.Recovery.recover_active_sessions()
    assert_receive {:tool_request_replayed, ^request_id}, 5_000
    refute_receive {:tool_execution_started, ^request_id}

    send(runner_pid, {:complete, request_id})

    assert_receive {:review_completed, _review_request_id}, 5_000

    assert_receive {:session_event,
                    %{type: "session_status_changed", payload: %{"status" => "completed"}}},
                   5_000

    events = Sessions.events_after(session.id)
    assert Enum.count(events, &(&1.type == "tool_requested")) == 2
    assert Enum.count(events, &(&1.type == "tool_completed")) == 2
  end

  defp assert_competing_claims_are_fenced(source, target, peer_node) do
    user = user_fixture()
    scope = Scope.for_user(user)

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
        title: "Competing distributed claims",
        model: "test:model"
      })

    local_claim = Task.async(fn -> Sessions.claim_ownership(session.id, source.boot_id) end)

    remote_claim =
      Task.async(fn ->
        :erpc.call(peer_node, Sessions, :claim_ownership, [session.id, target.boot_id])
      end)

    results = Task.await_many([local_claim, remote_claim], :infinity)
    assert Enum.count(results, &match?({:ok, %Kodo.Sessions.Ownership{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :session_owned})) == 1

    {:ok, winning_ownership} = Enum.find(results, &match?({:ok, _ownership}, &1))
    replacement = if winning_ownership.owner_boot_id == source.boot_id, do: target, else: source
    {:ok, new_ownership} = Sessions.transfer_ownership(winning_ownership, replacement.boot_id)

    assert {:error, :stale_ownership} =
             Sessions.append_event(session.id, "user_message", %{"content" => "stale"},
               ownership: winning_ownership
             )

    assert new_ownership.epoch > winning_ownership.epoch
  end

  defp assert_eventually_owned(session_id, expected_boot_id, peer_node, attempts \\ 10)

  defp assert_eventually_owned(session_id, expected_boot_id, _peer_node, 0) do
    assert Sessions.get_session!(session_id).owner_boot_id == expected_boot_id
  end

  defp assert_eventually_owned(session_id, expected_boot_id, peer_node, attempts) do
    if Sessions.get_session!(session_id).owner_boot_id == expected_boot_id do
      :ok
    else
      state = :erpc.call(peer_node, :sys, :get_state, [Kodo.Sessions.Recovery])

      if state.sweep_task do
        task_ref = Process.monitor(state.sweep_task.pid)
        assert_receive {:DOWN, ^task_ref, :process, _pid, _reason}, 1_000
      else
        :ok = :erpc.call(peer_node, Process, :send, [Kodo.Sessions.Recovery, :retry, []])
      end

      assert_eventually_owned(session_id, expected_boot_id, peer_node, attempts - 1)
    end
  end

  defp complete_approved_tool(scope, session, runner, approval_id) do
    assert {:ok, {_resolved, _status}} =
             Sessions.resolve_approval(scope, session.id, approval_id, "approved")

    assert_receive {:tool_request, request}, 5_000

    Phoenix.PubSub.broadcast(
      Kodo.PubSub,
      "runner_responses:#{runner.id}",
      {:runner_tool_response, runner.id,
       %{
         "protocol_version" => 4,
         "request_id" => request["request_id"],
         "status" => "success",
         "response" => %{"result" => "files_changed", "paths" => []}
       }}
    )

    assert_receive {:tool_request, review_request}, 5_000
    assert review_request["request"]["tool"] == "git_diff"

    Phoenix.PubSub.broadcast(
      Kodo.PubSub,
      "runner_responses:#{runner.id}",
      {:runner_tool_response, runner.id,
       %{
         "protocol_version" => 4,
         "request_id" => review_request["request_id"],
         "status" => "success",
         "response" => %{"result" => "output", "content" => "clean diff", "truncated" => false}
       }}
    )

    assert_receive {:session_event,
                    %{type: "session_status_changed", payload: %{"status" => "completed"}}},
                   5_000
  end

  defp receive_approval_id do
    assert_receive {:session_event,
                    %{type: "approval_requested", payload: %{"approval_id" => approval_id}}},
                   5_000

    approval_id
  end

  defp start_remote_control_plane!(peer_node, revision, generation) do
    repo_config =
      Repo.config()
      |> Keyword.delete(:pool)
      |> Keyword.delete(:ownership_timeout)

    options = instance_options(revision, generation, Atom.to_string(peer_node))
    agent_budgets = Application.fetch_env!(:kodo, :agent_budgets)

    {:ok, supervisor} =
      :erpc.call(peer_node, Kodo.Test.ClusterPeer, :start, [
        repo_config,
        options,
        agent_budgets,
        self()
      ])

    supervisor
  end

  defp start_instance_manager!(revision, generation, overrides \\ []) do
    options =
      revision
      |> instance_options(generation, Atom.to_string(node()))
      |> Keyword.merge(overrides)

    start_supervised!({InstanceManager, options})
  end

  defp instance_options(revision, generation, node_name) do
    [
      enabled: true,
      boot_id: Ecto.UUID.generate(),
      node_name: node_name,
      artifact_revision: revision,
      deployment_generation: generation,
      capacity: 10,
      protocol_capabilities: @capabilities,
      heartbeat_interval: :infinity,
      drain_timeout: 5_000
    ]
  end

  defp cleanup_cluster_rows do
    Repo.delete_all(Kodo.Cluster.PlacementOverride)
    Repo.delete_all(Kodo.Sessions.Event)
    Repo.delete_all(Kodo.Sessions.Session)
    Repo.delete_all(Kodo.Runners.Runner)
    Repo.delete_all(Kodo.Cluster.Instance)
    Repo.delete_all(Kodo.Accounts.UserToken)
    Repo.delete_all(Kodo.Accounts.User)
  end

  defp ensure_distributed_node! do
    if node() == :nonode@nohost do
      {_output, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _pid} = :net_kernel.start([:kodo_distributed_handoff_test, :shortnames])
    end
  end

  defp stop_peer(peer) do
    try do
      :peer.stop(peer)
    catch
      :exit, _reason -> :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:kodo, key)
  defp restore_env(key, value), do: Application.put_env(:kodo, key, value)
end
