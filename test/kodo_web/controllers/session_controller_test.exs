defmodule KodoWeb.SessionControllerTest do
  use KodoWeb.ConnCase

  alias Kodo.Runners
  alias Kodo.Sessions

  import Kodo.AccountsFixtures

  setup %{conn: conn} do
    previous_adapter = Application.get_env(:kodo, :llm_adapter)
    previous_test_pid = Application.get_env(:kodo, :fake_llm_test_pid)
    Application.put_env(:kodo, :llm_adapter, Kodo.Test.FakeLLM)
    Application.put_env(:kodo, :fake_llm_test_pid, self())

    on_exit(fn ->
      if previous_adapter do
        Application.put_env(:kodo, :llm_adapter, previous_adapter)
      else
        Application.delete_env(:kodo, :llm_adapter)
      end

      if previous_test_pid do
        Application.put_env(:kodo, :fake_llm_test_pid, previous_test_pid)
      else
        Application.delete_env(:kodo, :fake_llm_test_pid)
      end
    end)

    {:ok, runner} =
      Runners.register(%{
        workspace_root: "/work/#{Ecto.UUID.generate()}",
        platform: "linux",
        architecture: "x86_64",
        runner_version: "0.1.0",
        protocol_version: 3,
        capabilities: []
      })

    user = user_fixture()
    %{conn: authenticate_agent(conn, user), runner: runner, user: user}
  end

  test "an API-driven coding turn dispatches a tool and replays from persisted events", %{
    conn: conn,
    runner: runner
  } do
    session = create_session(conn, runner)
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session["id"]}")
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    response =
      conn
      |> post_json(~p"/api/sessions/#{session["id"]}/messages", %{content: "Fix it"})
      |> json_response(202)

    assert response == %{"status" => "running"}

    assert_receive {:tool_request, request}
    assert request["request"]["tool"] == "apply_patch"

    Phoenix.PubSub.broadcast(
      Kodo.PubSub,
      "runner_responses:#{runner.id}",
      {:runner_tool_response, runner.id,
       %{
         "protocol_version" => 3,
         "request_id" => request["request_id"],
         "status" => "success",
         "response" => %{"result" => "files_changed", "paths" => ["lib/greeting.ex"]}
       }}
    )

    assert_receive {:session_event,
                    %{type: "session_status_changed", payload: %{"status" => "completed"}}}

    replay =
      conn
      |> recycle(["accept", "authorization"])
      |> get(~p"/api/sessions/#{session["id"]}?after_sequence=1")
      |> json_response(200)

    assert replay["session"]["status"] == "completed"
    sequences = Enum.map(replay["events"], & &1["sequence"])
    assert sequences == Enum.to_list(2..List.last(sequences))
    assert Enum.any?(replay["events"], &(&1["type"] == "tool_completed"))

    {:ok, active} = Sessions.ensure_started(session["id"])
    :ok = DynamicSupervisor.terminate_child(Kodo.SessionSupervisor, active)
    assert {:ok, projection} = Sessions.active_state(session["id"])
    assert projection.status == "completed"
    assert List.last(projection.messages)["content"] == "The fix is complete."
  end

  test "cancelling an active model call records a durable terminal state", %{
    conn: conn,
    runner: runner
  } do
    session = create_session(conn, runner)

    assert conn
           |> post_json(~p"/api/sessions/#{session["id"]}/messages", %{content: "wait"})
           |> json_response(202)

    assert_receive :fake_llm_waiting

    response =
      conn
      |> recycle(["accept", "authorization"])
      |> post_json(~p"/api/sessions/#{session["id"]}/cancel", %{})
      |> json_response(200)

    assert response == %{"status" => "cancelled"}
    assert Sessions.get_session!(session["id"]).status == "cancelled"
    assert Enum.any?(Sessions.events_after(session["id"]), &(&1.type == "session_cancelled"))
  end

  test "a safe-policy tool waits for an authenticated approval", %{
    conn: conn,
    runner: runner
  } do
    session = create_session(conn, runner, approval_policy: "safe")
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session["id"]}")
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    assert conn
           |> post_json(~p"/api/sessions/#{session["id"]}/messages", %{content: "Fix it"})
           |> json_response(202)

    assert_receive {:session_event,
                    %{
                      type: "approval_requested",
                      payload: %{"approval_id" => approval_id, "name" => "apply_patch"}
                    }}

    refute_received {:tool_request, _request}

    response =
      conn
      |> recycle(["accept", "authorization"])
      |> post_json(~p"/api/sessions/#{session["id"]}/approvals/#{approval_id}", %{
        decision: "approved"
      })
      |> json_response(200)

    assert response == %{"decision" => "approved", "status" => "running"}
    assert_receive {:tool_request, request}

    assert conn
           |> recycle(["accept", "authorization"])
           |> post_json(~p"/api/sessions/#{session["id"]}/approvals/#{approval_id}", %{
             decision: "approved"
           })
           |> json_response(200)

    assert conn
           |> recycle(["accept", "authorization"])
           |> post_json(~p"/api/sessions/#{session["id"]}/approvals/#{approval_id}", %{
             decision: "denied"
           })
           |> json_response(409)

    Phoenix.PubSub.broadcast(
      Kodo.PubSub,
      "runner_responses:#{runner.id}",
      {:runner_tool_response, runner.id,
       %{
         "protocol_version" => 3,
         "request_id" => request["request_id"],
         "status" => "success",
         "response" => %{"result" => "files_changed", "paths" => []}
       }}
    )

    assert_receive {:session_event,
                    %{type: "session_status_changed", payload: %{"status" => "completed"}}}
  end

  test "provider errors become explicit failed session states", %{conn: conn, runner: runner} do
    session = create_session(conn, runner)
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session["id"]}")

    assert conn
           |> post_json(~p"/api/sessions/#{session["id"]}/messages", %{
             content: "provider failure"
           })
           |> json_response(202)

    assert_receive {:session_event,
                    %{type: "session_status_changed", payload: %{"status" => "failed"}}}

    assert Enum.any?(Sessions.events_after(session["id"]), &(&1.type == "session_failed"))
  end

  test "rejects malformed identifiers, cursors, and message bodies", %{conn: conn} do
    assert conn |> get(~p"/api/sessions/not-a-uuid") |> json_response(404)

    assert conn
           |> recycle(["accept", "authorization"])
           |> post_json(~p"/api/sessions/not-a-uuid/messages", %{content: 42})
           |> json_response(422)
  end

  test "sessions are owned by the authenticated account", %{
    conn: conn,
    runner: runner,
    user: user
  } do
    session = create_session(conn, runner)
    assert Sessions.get_session!(session["id"]).user_id == user.id

    other_user = user_fixture()

    assert build_conn()
           |> authenticate_agent(other_user)
           |> get(~p"/api/sessions/#{session["id"]}")
           |> json_response(404)

    assert build_conn()
           |> authenticate_agent(other_user)
           |> post_json(~p"/api/sessions/#{session["id"]}/messages", %{content: "intrude"})
           |> json_response(404)

    assert build_conn()
           |> authenticate_agent(other_user)
           |> post_json(~p"/api/sessions/#{session["id"]}/cancel", %{})
           |> json_response(404)
  end

  defp create_session(conn, runner, opts \\ []) do
    session =
      conn
      |> post_json(~p"/api/sessions", %{
        runner_id: runner.id,
        title: "Fix greeting",
        model: "test:model",
        approval_policy: Keyword.get(opts, :approval_policy, "standard")
      })
      |> json_response(201)
      |> Map.fetch!("session")

    on_exit(fn ->
      case Registry.lookup(Kodo.SessionRegistry, session["id"]) do
        [{pid, _value}] -> DynamicSupervisor.terminate_child(Kodo.SessionSupervisor, pid)
        [] -> :ok
      end
    end)

    session
  end

  defp post_json(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end
end
