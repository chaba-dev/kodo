defmodule Kodo.Cluster.DiscoveryTest do
  use ExUnit.Case, async: false

  alias Kodo.Cluster.Discovery
  alias Kodo.Runners

  test "discovers live session and runner processes and removes them on exit" do
    session_id = Ecto.UUID.generate()
    runner_id = Ecto.UUID.generate()
    parent = self()

    pid =
      spawn_link(fn ->
        :ok = Discovery.join_session(session_id)
        :ok = Discovery.join_runner(runner_id)
        send(parent, :joined)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :joined
    assert Discovery.session(session_id) == {:ok, pid}
    assert Discovery.runner(runner_id) == {:ok, pid}

    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert_eventually_empty(:session, session_id)
    assert_eventually_empty(:runner, runner_id)
  end

  test "routes runner messages through distributed discovery without a local Registry entry" do
    runner_id = Ecto.UUID.generate()
    :ok = Discovery.join_runner(runner_id)

    request = %{"protocol_version" => 4, "request_id" => Ecto.UUID.generate()}
    lease = %{"session_id" => Ecto.UUID.generate(), "ownership_epoch" => 1, "ttl_ms" => 15_000}

    assert Registry.lookup(Kodo.RunnerRegistry, runner_id) == []
    assert :ok = Runners.dispatch(runner_id, request)
    assert_receive {:tool_request, ^request}
    assert :ok = Runners.renew_authority(runner_id, lease)
    assert_receive {:authority_lease, ^lease}
  end

  test "publishes immediate membership loss signals" do
    runner_id = Ecto.UUID.generate()
    :ok = Discovery.subscribe()
    parent = self()

    pid =
      spawn_link(fn ->
        :ok = Discovery.join_runner(runner_id)
        send(parent, :joined)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :joined

    assert_receive {:cluster_membership, :join, :runner, ^runner_id, [^pid], [^pid]}

    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert_receive {:cluster_membership, :leave, :runner, ^runner_id, [^pid], []}
  end

  defp assert_eventually_empty(kind, id) do
    ref = make_ref()
    {monitor_ref, _members} = :pg.monitor(Discovery.scope(), Discovery.group(kind, id))
    send(self(), ref)
    assert_receive ^ref

    if Discovery.members(kind, id) != [] do
      assert_receive {^monitor_ref, :leave, _group, _pids}
    end

    assert Discovery.members(kind, id) == []
    :pg.demonitor(Discovery.scope(), monitor_ref)
  end
end
