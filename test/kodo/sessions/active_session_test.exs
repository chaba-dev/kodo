defmodule Kodo.Sessions.ActiveSessionTest do
  use Kodo.DataCase

  alias Kodo.Runners
  alias Kodo.Sessions
  alias Kodo.Sessions.ActiveSession

  setup do
    {:ok, runner} =
      Runners.register(%{
        workspace_root: "/work/#{Ecto.UUID.generate()}",
        platform: "linux",
        architecture: "x86_64",
        runner_version: "0.1.0",
        protocol_version: 3,
        capabilities: []
      })

    {:ok, session} =
      Sessions.create_session(%{
        runner_id: runner.id,
        title: "Recover me",
        model: "openai:gpt-4o-mini"
      })

    on_exit(fn ->
      case Registry.lookup(Kodo.SessionRegistry, session.id) do
        [{pid, _value}] -> DynamicSupervisor.terminate_child(Kodo.SessionSupervisor, pid)
        [] -> :ok
      end
    end)

    %{session: session}
  end

  test "ensures only one supervised process per session", %{session: session} do
    assert {:ok, first} = Sessions.ensure_started(session.id)
    assert {:ok, second} = Sessions.ensure_started(session.id)
    assert first == second
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

  test "fails an interrupted running turn instead of accepting it as idle", %{session: session} do
    {:ok, _status} = Sessions.set_status(session.id, "running")

    assert {:ok, projection} = Sessions.active_state(session.id)
    assert projection.status == "failed"
    assert Enum.any?(Sessions.events_after(session.id), &(&1.type == "session_failed"))
  end

  test "reloads committed events in sequence when notifications arrive out of order", %{
    session: session
  } do
    {:ok, pid} = Sessions.ensure_started(session.id)
    {:ok, second} = Sessions.append_event(session.id, "user_message", %{"content" => "one"})
    {:ok, third} = Sessions.append_event(session.id, "user_message", %{"content" => "two"})

    send(pid, {:session_event, third})
    _ = :sys.get_state(pid)
    send(pid, {:session_event, second})
    _ = :sys.get_state(pid)

    projection = ActiveSession.state(pid)
    assert Enum.map(projection.messages, & &1["content"]) == ["one", "two"]
    assert projection.last_sequence == 3
  end
end
