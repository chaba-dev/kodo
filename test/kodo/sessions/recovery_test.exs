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

  defp start_recovery!(id) do
    start_supervised!(%{
      id: id,
      start:
        {Recovery, :start_link,
         [
           [
             name: nil,
             coordinated: true,
             election_retry_interval: 10,
             sweep_interval: :infinity
           ]
         ]},
      restart: :temporary
    })
  end
end
