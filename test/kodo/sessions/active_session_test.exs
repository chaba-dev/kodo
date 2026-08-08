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
    assert second != first

    projection = ActiveSession.state(second)
    assert projection.title == "Recover me"
    assert projection.messages == [%{"role" => "user", "content" => "Fix the bug"}]
    assert projection.last_sequence == 2
  end
end
