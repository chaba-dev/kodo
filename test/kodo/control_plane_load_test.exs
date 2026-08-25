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
        protocol_version: 5,
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

  test "control-plane query counts stay constant as completed history grows", context do
    for number <- 1..25 do
      assert {:ok, _session} =
               Sessions.create_session(context.scope, %{
                 runner_id: context.session.runner_id,
                 title: "Historical session #{number}",
                 model: "test:model"
               })
    end

    for number <- 1..5 do
      assert {:ok, session} =
               Sessions.create_session(context.scope, %{
                 runner_id: context.session.runner_id,
                 title: "Active session #{number}",
                 model: "test:model"
               })

      assert {:ok, _status} = Sessions.set_status(session.id, "running")
    end

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
    assert length(Sessions.list_active_sessions()) == 6
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

  test "event bursts refresh only the affected connected user's row", context do
    other_clients =
      for number <- 1..4 do
        scope = user_scope_fixture()

        {:ok, runner} =
          Runners.register(scope, %{
            workspace_root: "/work/client-#{number}",
            platform: "linux",
            architecture: "x86_64",
            runner_version: "0.1.0",
            protocol_version: 5,
            capabilities: []
          })

        {:ok, session} =
          Sessions.create_session(scope, %{
            runner_id: runner.id,
            title: "Other client #{number}",
            model: "test:model"
          })

        {scope, session}
      end

    clients = [{context.scope, context.session} | other_clients]
    test_pid = self()

    for {{scope, _session}, number} <- Enum.with_index(clients) do
      start_supervised!(%{
        id: {:session_index_client, number},
        start: {Task, :start_link, [fn -> session_index_client(scope, test_pid) end]},
        restart: :temporary
      })
    end

    for _client <- clients, do: assert_receive(:session_index_client_ready)

    handler_id = "session-index-load-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:kodo, :control_plane, :query],
        fn _event, _measurements, metadata, test_pid ->
          if metadata.options[:operation] == :session_index_refresh,
            do: send(test_pid, :session_index_refresh_query)
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    for number <- 1..20 do
      assert {:ok, _event} =
               Sessions.append_event(
                 context.session.id,
                 "assistant_message_started",
                 %{
                   "invocation" => number
                 },
                 ownership: context.ownership
               )
    end

    refute_receive :session_index_refresh_query

    assert {:ok, _status} =
             Sessions.set_status(context.session.id, "awaiting_approval", "agent",
               ownership: context.ownership
             )

    assert_receive {:session_index_client_refreshed, session_id}
    assert session_id == context.session.id
    assert_receive :session_index_refresh_query
    assert_receive :session_index_refresh_query
    refute_receive :session_index_refresh_query
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

  defp session_index_client(scope, parent) do
    :ok = Sessions.subscribe_index(scope)
    send(parent, :session_index_client_ready)

    receive do
      {:session_index_changed, session_id} ->
        _session = Sessions.get_session_for_index(scope, session_id)
        send(parent, {:session_index_client_refreshed, session_id})
    end
  end
end
