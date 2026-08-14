defmodule Kodo.Cluster.PlacementTest do
  use Kodo.DataCase

  alias Kodo.Cluster.Instance
  alias Kodo.Cluster.Instances
  alias Kodo.Cluster.Placement
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

    %{runner: runner, scope: scope}
  end

  test "places across different artifact revisions when session protocols are compatible",
       context do
    session = create_session(context)
    {:ok, compatible} = Instances.register(instance_attrs("new-revision"))

    assert {:ok, selected, selected_node} = Placement.select(session.id, 60)
    assert selected.boot_id == compatible.boot_id
    assert selected_node == node()
  end

  test "excludes incompatible, draining, stale, and unreachable instances", context do
    session = create_session(context)
    {:ok, compatible} = Instances.register(instance_attrs("compatible"))

    {:ok, _incompatible} =
      Instances.register(
        instance_attrs("incompatible", protocol_capabilities: ["session-ownership-v1"])
      )

    {:ok, draining} = Instances.register(instance_attrs("draining"))
    {:ok, _draining} = Instances.begin_drain(draining)
    {:ok, stale} = Instances.register(instance_attrs("stale"))

    Instance
    |> where([instance], instance.boot_id == ^stale.boot_id)
    |> Kodo.Repo.update_all(set: [last_seen_at: DateTime.add(DateTime.utc_now(), -120, :second)])

    {:ok, _unreachable} =
      Instances.register(instance_attrs("unreachable", node_name: "missing@cluster"))

    assert {:ok, selected, _node} = Placement.select(session.id, 60)
    assert selected.boot_id == compatible.boot_id
  end

  test "prefers the durable owner even when its declared capacity is full", context do
    owned = create_session(context)
    other = create_session(context)
    {:ok, owner} = Instances.register(instance_attrs("owner", capacity: 1))
    {:ok, _ownership} = Sessions.claim_ownership(owned.id, owner.boot_id)

    assert {:ok, selected, _node} = Placement.select(owned.id, 60)
    assert selected.boot_id == owner.boot_id
    assert {:error, :no_compatible_instance} = Placement.select(other.id, 60)
  end

  test "chooses the least-loaded compatible instance relative to capacity", context do
    first = create_session(context)
    second = create_session(context)
    unowned = create_session(context)
    {:ok, busy} = Instances.register(instance_attrs("busy", capacity: 2))
    {:ok, available} = Instances.register(instance_attrs("available", capacity: 4))
    {:ok, _ownership} = Sessions.claim_ownership(first.id, busy.boot_id)
    {:ok, _ownership} = Sessions.claim_ownership(second.id, available.boot_id)

    assert {:ok, selected, _node} = Placement.select(unowned.id, 60)
    assert selected.boot_id == available.boot_id
  end

  defp create_session(%{runner: runner, scope: scope}) do
    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Placement #{Ecto.UUID.generate()}",
        model: "test:model"
      })

    session
  end

  defp instance_attrs(revision, overrides \\ []) do
    Map.merge(
      %{
        boot_id: Ecto.UUID.generate(),
        node_name: Atom.to_string(node()),
        artifact_revision: revision,
        deployment_generation: 1,
        ready: true,
        draining: false,
        capacity: 1,
        protocol_capabilities: ["session-events-v1", "session-ownership-v1"]
      },
      Map.new(overrides)
    )
  end
end
