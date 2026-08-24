defmodule Kodo.ControlPlaneLoadTest do
  use Kodo.DataCase

  import Kodo.AccountsFixtures

  alias Kodo.Cluster.Instances
  alias Kodo.Runners
  alias Kodo.Sessions

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
        title: "Measured session",
        model: "test:model"
      })

    {:ok, _status} = Sessions.set_status(session.id, "running")

    {:ok, instance} =
      Instances.register(%{
        boot_id: Ecto.UUID.generate(),
        node_name: "load-test@localhost",
        artifact_revision: "test",
        deployment_generation: 1,
        ready: true,
        draining: false,
        capacity: 1,
        protocol_capabilities: ["session-ownership-v1"]
      })

    {:ok, ownership} = Sessions.claim_ownership(session.id, instance.boot_id)

    %{instance: instance, ownership: ownership, scope: scope, session: session}
  end

  test "labels bounded control-plane query counts and durations", context do
    handler_id = "control-plane-load-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:kodo, :control_plane, :query],
        fn _event, measurements, metadata, test_pid ->
          send(test_pid, {:control_plane_query, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _instance} = Instances.heartbeat(context.instance)
    assert [_session] = Sessions.list_active_sessions()
    assert :ok = Sessions.assert_owner(context.ownership)
    assert %{id: session_id} = Sessions.get_session_for_index(context.scope, context.session.id)
    assert session_id == context.session.id

    operations = collect_operations(6)

    assert Enum.frequencies(operations) == %{
             instance_heartbeat: 2,
             ownership_fencing: 1,
             recovery_discovery: 1,
             session_index_refresh: 2
           }
  end

  test "active recovery uses the partial index" do
    Repo.query!("SET LOCAL enable_seqscan = off")

    plan =
      Repo.query!("""
      EXPLAIN SELECT * FROM sessions
      WHERE status IN ('running', 'awaiting_approval')
      """)
      |> Map.fetch!(:rows)
      |> List.flatten()
      |> Enum.join("\n")

    assert plan =~ "sessions_active_recovery_index"
  end

  defp collect_operations(remaining, operations \\ [])

  defp collect_operations(0, operations), do: Enum.reverse(operations)

  defp collect_operations(remaining, operations) do
    assert_receive {:control_plane_query, %{total_time: duration}, %{options: options}}
    assert duration >= 0

    collect_operations(remaining - 1, [Keyword.fetch!(options, :operation) | operations])
  end
end
