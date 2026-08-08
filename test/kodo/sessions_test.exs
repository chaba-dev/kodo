defmodule Kodo.SessionsTest do
  use Kodo.DataCase

  alias Kodo.Runners
  alias Kodo.Sessions

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

    %{runner: runner}
  end

  test "creates a session with its reconstructible creation event", %{runner: runner} do
    assert {:ok, session} =
             Sessions.create_session(%{
               runner_id: runner.id,
               title: "Fix greeting",
               model: "openai:gpt-4o-mini"
             })

    assert [event] = Sessions.events_after(session.id)
    assert event.sequence == 1
    assert event.type == "session_created"
    assert event.payload["runner_id"] == runner.id
    assert event.payload["status"] == "idle"
  end

  test "allocates gap-free event sequences and replays after a cursor", %{runner: runner} do
    {:ok, session} =
      Sessions.create_session(%{
        runner_id: runner.id,
        title: "Replay",
        model: "openai:gpt-4o-mini"
      })

    assert {:ok, second} = Sessions.append_event(session.id, "user_message", %{"content" => "go"})
    assert {:ok, third} = Sessions.append_event(session.id, "assistant_message_started", %{})

    assert [^third] = Sessions.events_after(session.id, second.sequence)
    assert Enum.map(Sessions.events_after(session.id), & &1.sequence) == [1, 2, 3]
  end

  test "persists status and its transition atomically", %{runner: runner} do
    {:ok, session} =
      Sessions.create_session(%{
        runner_id: runner.id,
        title: "Cancel",
        model: "openai:gpt-4o-mini"
      })

    assert {:ok, {%{status: "cancelled"}, event}} =
             Sessions.set_status(session.id, "cancelled", "user")

    assert event.type == "session_status_changed"
    assert event.payload == %{"status" => "cancelled"}
  end
end
