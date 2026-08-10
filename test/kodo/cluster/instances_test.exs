defmodule Kodo.Cluster.InstancesTest do
  use Kodo.DataCase

  alias Kodo.Cluster.InstanceManager
  alias Kodo.Cluster.Instances

  test "registers immutable boot and deployment identity with placement metadata" do
    attrs = valid_attrs()

    assert {:ok, instance} = Instances.register(attrs)
    assert instance.boot_id == attrs.boot_id
    assert instance.node_name == "kodo@node-a"
    assert instance.artifact_revision == "sha-abc"
    assert instance.deployment_generation == 12
    assert instance.ready
    refute instance.draining
    assert instance.capacity == 4
    assert instance.protocol_capabilities == ["session-events-v1"]

    assert {:error, changeset} = Instances.register(attrs)
    assert "has already been taken" in errors_on(changeset).boot_id
  end

  test "rejects invalid placement metadata" do
    attrs = %{valid_attrs() | deployment_generation: -1, capacity: 0}

    assert {:error, changeset} = Instances.register(attrs)
    assert "must be greater than or equal to 0" in errors_on(changeset).deployment_generation
    assert "must be greater than 0" in errors_on(changeset).capacity
  end

  test "rejects an instance that is ready and draining at the same time" do
    attrs = %{valid_attrs() | ready: true, draining: true}

    assert {:error, changeset} = Instances.register(attrs)
    assert "cannot be ready while draining" in errors_on(changeset).ready
  end

  test "registration uses the database clock instead of caller wall time" do
    Kodo.Repo.query!("SET LOCAL TIME ZONE 'Pacific/Honolulu'")
    caller_time = DateTime.add(DateTime.utc_now(), 86_400, :second)

    assert {:ok, instance} =
             valid_attrs()
             |> Map.put(:last_seen_at, caller_time)
             |> Instances.register_current()

    assert DateTime.before?(instance.last_seen_at, caller_time)

    %{rows: [[database_utc]]} =
      Kodo.Repo.query!("SELECT timezone('UTC', clock_timestamp())")

    assert abs(
             NaiveDateTime.diff(DateTime.to_naive(instance.last_seen_at), database_utc, :second)
           ) < 2
  end

  test "refuses to reuse a boot id with different immutable metadata" do
    attrs = valid_attrs()

    assert {:ok, _instance} = Instances.register_current(attrs)

    assert {:error, :boot_identity_mismatch} =
             Instances.register_current(%{attrs | artifact_revision: "different-sha"})
  end

  test "manager registers one boot incarnation and enters draining state" do
    boot_id = Ecto.UUID.generate()

    pid =
      start_supervised!({
        InstanceManager,
        name: nil,
        boot_id: boot_id,
        node_name: "kodo@node-b",
        artifact_revision: "sha-def",
        deployment_generation: 13,
        capacity: 2,
        protocol_capabilities: ["runner-v3"],
        heartbeat_interval: :infinity
      })

    assert instance = InstanceManager.current_instance(pid)
    assert instance.boot_id == boot_id
    assert instance.ready
    refute instance.draining

    assert {:ok, draining} = InstanceManager.begin_drain(pid)
    refute draining.ready
    assert draining.draining
    assert Instances.get(boot_id).draining
  end

  test "application preparation for shutdown starts an explicit drain" do
    pid =
      start_supervised!({
        InstanceManager,
        boot_id: Ecto.UUID.generate(),
        node_name: "kodo@node-shutdown",
        artifact_revision: "sha-shutdown",
        deployment_generation: 14,
        capacity: 2,
        protocol_capabilities: ["runner-v3"],
        heartbeat_interval: :infinity
      })

    assert :application_state = Kodo.Application.prep_stop(:application_state)
    instance = InstanceManager.current_instance(pid)
    refute instance.ready
    assert instance.draining
  end

  test "manager restart preserves the BEAM boot incarnation" do
    boot_id = Ecto.UUID.generate()
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    child =
      {InstanceManager,
       name: nil,
       boot_id: boot_id,
       node_name: "kodo@node-c",
       artifact_revision: "sha-ghi",
       deployment_generation: 14,
       capacity: 2,
       protocol_capabilities: ["runner-v3"],
       heartbeat_interval: :infinity}

    assert {:ok, first} = DynamicSupervisor.start_child(supervisor, child)
    assert {:ok, draining} = InstanceManager.begin_drain(first)
    assert draining.draining

    ref = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^ref, :process, ^first, :killed}
    _ = :sys.get_state(supervisor)

    assert [{:undefined, second, :worker, [InstanceManager]}] =
             DynamicSupervisor.which_children(supervisor)

    refute second == first
    instance = InstanceManager.current_instance(second)
    assert instance.boot_id == boot_id
    refute instance.ready
    assert instance.draining

    assert Kodo.Repo.aggregate(
             from(instance in Kodo.Cluster.Instance, where: instance.boot_id == ^boot_id),
             :count
           ) == 1
  end

  test "concurrent registration of one boot incarnation is idempotent" do
    attrs = valid_attrs()
    parent = self()

    repo =
      start_supervised!({
        Kodo.Repo,
        name: nil, pool: DBConnection.ConnectionPool, pool_size: 8
      })

    tasks =
      for _index <- 1..8 do
        Task.async(fn ->
          Kodo.Repo.put_dynamic_repo(repo)
          send(parent, {:registration_ready, self()})
          receive do: (:register -> Instances.register_current(attrs))
        end)
      end

    task_pids =
      for _index <- 1..8 do
        assert_receive {:registration_ready, task_pid}
        task_pid
      end

    Enum.each(task_pids, &send(&1, :register))
    results = Task.await_many(tasks, :infinity)

    assert Enum.all?(results, &match?({:ok, %Kodo.Cluster.Instance{}}, &1))

    previous_repo = Kodo.Repo.put_dynamic_repo(repo)

    assert Kodo.Repo.aggregate(
             from(instance in Kodo.Cluster.Instance, where: instance.boot_id == ^attrs.boot_id),
             :count
           ) == 1

    Kodo.Repo.delete_all(
      from(instance in Kodo.Cluster.Instance, where: instance.boot_id == ^attrs.boot_id)
    )

    Kodo.Repo.put_dynamic_repo(previous_repo)
  end

  test "eligible instances must be ready, non-draining, and recently seen by PostgreSQL" do
    assert {:ok, fresh} = Instances.register_current(valid_attrs())
    assert {:ok, draining} = Instances.register_current(valid_attrs())
    assert {:ok, stale} = Instances.register_current(valid_attrs())
    assert {:ok, _draining} = Instances.begin_drain(draining)

    old_timestamp = DateTime.add(DateTime.utc_now(), -120, :second)

    Kodo.Cluster.Instance
    |> where([instance], instance.boot_id == ^stale.boot_id)
    |> Kodo.Repo.update_all(set: [last_seen_at: old_timestamp])

    assert Enum.map(Instances.list_eligible(60), & &1.boot_id) == [fresh.boot_id]
  end

  defp valid_attrs do
    %{
      boot_id: Ecto.UUID.generate(),
      node_name: "kodo@node-a",
      artifact_revision: "sha-abc",
      deployment_generation: 12,
      ready: true,
      draining: false,
      capacity: 4,
      protocol_capabilities: ["session-events-v1"]
    }
  end
end
