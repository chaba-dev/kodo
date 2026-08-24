defmodule Kodo.Sessions.RecoveryTest do
  use Kodo.DataCase

  alias Kodo.Sessions.Recovery

  test "elects one sweeper and transfers leadership when it stops" do
    handler_id = "recovery-election-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:kodo, :control_plane, :query],
        fn _event, _measurements, metadata, test_pid ->
          if metadata.options[:operation] == :recovery_discovery,
            do: send(test_pid, :recovery_discovery)
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    first = start_recovery!(:first_recovery)
    second = start_recovery!(:second_recovery)

    assert_receive :recovery_discovery, 1_000
    refute_receive :recovery_discovery, 100

    {leader_id, follower} =
      case {:sys.get_state(first).leader?, :sys.get_state(second).leader?} do
        {true, false} -> {:first_recovery, second}
        {false, true} -> {:second_recovery, first}
      end

    assert :ok = stop_supervised(leader_id)
    assert_receive :recovery_discovery, 1_000
    assert :sys.get_state(follower).leader?
  end

  test "relinquishes leadership when the advisory-lock connection is lost" do
    attach_recovery_query_telemetry()

    first = start_recovery!(:first_database_recovery, lease_backend: :database)
    second = start_recovery!(:second_database_recovery, lease_backend: :database)

    {leader, follower} = await_database_leader(first, second)
    leader_state = :sys.get_state(leader)
    lease_ref = Process.monitor(leader_state.lease_pid)

    assert is_integer(leader_state.lease_backend_pid)

    assert [[true]] =
             Repo.query!("SELECT pg_terminate_backend($1)", [leader_state.lease_backend_pid]).rows

    assert_receive {:DOWN, ^lease_ref, :process, _lease_pid, _reason}, 1_000

    assert_receive {:recovery_query, :recovery_election, _pid}, 1_000
    assert_receive {:recovery_query, :recovery_lease, _pid}, 1_000
    assert_receive {:recovery_query, :recovery_discovery, ^follower}, 1_000

    refute :sys.get_state(leader).leader?
    assert :sys.get_state(follower).leader?

    stop_recovery!(:first_database_recovery, first)
    stop_recovery!(:second_database_recovery, second)
  end

  test "cancels an in-progress sweep when its advisory lease is lost" do
    attach_recovery_query_telemetry()
    test_pid = self()

    sweep = fn ->
      send(test_pid, {:recovery_sweep_started, self()})

      receive do
        :continue -> send(test_pid, {:recovery_sweep_continued, self()})
      end

      :ok
    end

    first =
      start_recovery!(:first_blocked_recovery,
        lease_backend: :database,
        sweep: sweep
      )

    second =
      start_recovery!(:second_blocked_recovery,
        lease_backend: :database,
        sweep: sweep
      )

    {leader, follower} = await_database_leader(first, second)
    assert_receive {:recovery_sweep_started, old_sweep}
    old_sweep_ref = Process.monitor(old_sweep)
    backend_pid = :sys.get_state(leader).lease_backend_pid

    assert [[true]] = Repo.query!("SELECT pg_terminate_backend($1)", [backend_pid]).rows
    assert_receive {:DOWN, ^old_sweep_ref, :process, ^old_sweep, :killed}, 1_000
    assert_receive {:recovery_sweep_started, new_sweep}, 1_000
    refute new_sweep == old_sweep
    assert :sys.get_state(follower).leader?

    send(old_sweep, :continue)
    refute_receive {:recovery_sweep_continued, ^old_sweep}
    send(new_sweep, :continue)
    assert_receive {:recovery_sweep_continued, ^new_sweep}

    stop_recovery!(:first_blocked_recovery, first)
    stop_recovery!(:second_blocked_recovery, second)
  end

  defp start_recovery!(id, extra_opts \\ []) do
    start_supervised!(%{
      id: id,
      start:
        {Recovery, :start_link,
         [
           Keyword.merge(
             [
               name: nil,
               coordinated: true,
               election_retry_interval: 10,
               sweep_interval: :infinity
             ],
             extra_opts
           )
         ]},
      restart: :temporary
    })
  end

  defp await_database_leader(first, second) do
    case {:sys.get_state(first), :sys.get_state(second)} do
      {%{leader?: true}, %{leader?: false}} ->
        {first, second}

      {%{leader?: false}, %{leader?: true}} ->
        {second, first}

      _states ->
        assert_receive {:recovery_query, operation, _pid}, 1_000
        assert operation in [:recovery_election, :recovery_lease, :recovery_discovery]
        await_database_leader(first, second)
    end
  end

  defp attach_recovery_query_telemetry do
    handler_id = "recovery-database-lease-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:kodo, :control_plane, :query],
        fn _event, _measurements, metadata, test_pid ->
          send(test_pid, {:recovery_query, metadata.options[:operation], self()})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp stop_recovery!(id, recovery) do
    lease_pid = :sys.get_state(recovery).lease_pid
    lease_ref = if lease_pid, do: Process.monitor(lease_pid)
    assert :ok = stop_supervised(id)

    if lease_pid do
      assert_receive {:DOWN, ^lease_ref, :process, ^lease_pid, _reason}
    end
  end
end
