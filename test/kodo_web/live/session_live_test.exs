defmodule KodoWeb.SessionLiveTest do
  use KodoWeb.ConnCase

  import Kodo.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Kodo.Cluster.Discovery
  alias Kodo.Runners
  alias Kodo.Sessions

  setup %{conn: conn} do
    user = user_fixture()
    scope = Kodo.Accounts.Scope.for_user(user)

    {:ok, runner} =
      Runners.register(scope, %{
        workspace_root: "/work/kodo",
        name: "kodo",
        platform: "linux",
        architecture: "x86_64",
        runner_version: "0.1.0",
        protocol_version: 4,
        capabilities: []
      })

    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Fix the greeting",
        model: "test:model",
        approval_policy: "safe"
      })

    %{conn: log_in_user(conn, user), runner: runner, scope: scope, session: session}
  end

  test "session routes require authentication", %{session: session} do
    conn = Phoenix.ConnTest.build_conn()
    login_path = ~p"/users/log-in"

    assert {:error, {:redirect, %{to: ^login_path}}} = live(conn, ~p"/sessions")

    assert {:error, {:redirect, %{to: ^login_path}}} =
             live(conn, ~p"/sessions/#{session.id}")
  end

  test "lists owned sessions and updates runner connection state", %{
    conn: conn,
    runner: runner,
    scope: scope,
    session: session
  } do
    {:ok, view, _html} = live(conn, ~p"/sessions")

    assert has_element?(view, "#session-index")
    assert has_element?(view, "#workspace-placeholder")
    assert has_element?(view, "#sessions-#{session.id}", "Fix the greeting")
    assert has_element?(view, "#sessions-#{session.id}", "Offline")

    :ok = Discovery.join_runner(runner.id, self())

    send(
      view.pid,
      {:cluster_membership, :join, :runner, runner.id, [self()], [self()]}
    )

    assert has_element?(view, "#sessions-#{session.id}", "Online")

    {:ok, new_session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Created while watching",
        model: "test:model"
      })

    assert has_element?(view, "#sessions-#{new_session.id}", "Created while watching")
  end

  test "does not expose another user's session", %{conn: conn} do
    other_scope = user_scope_fixture()

    {:ok, other_runner} =
      Runners.register(other_scope, %{
        workspace_root: "/work/other",
        platform: "linux",
        architecture: "x86_64",
        runner_version: "0.1.0",
        protocol_version: 4,
        capabilities: []
      })

    {:ok, other_session} =
      Sessions.create_session(other_scope, %{
        runner_id: other_runner.id,
        title: "Private work",
        model: "test:model"
      })

    assert {:error, {:live_redirect, %{to: "/sessions"}}} =
             live(conn, ~p"/sessions/#{other_session.id}")
  end

  test "replays messages, tool output, and the latest diff", %{
    conn: conn,
    session: session
  } do
    {:ok, _user_event} =
      Sessions.append_event(session.id, "user_message", %{
        "role" => "user",
        "content" => "Please fix it"
      })

    {:ok, _assistant_event} =
      Sessions.append_event(session.id, "assistant_message_completed", %{
        "role" => "assistant",
        "content" => "The fix is ready"
      })

    tool_call_id = Ecto.UUID.generate()

    {:ok, _requested} =
      Sessions.append_event(session.id, "tool_requested", %{
        "tool_call_id" => tool_call_id,
        "request_id" => Ecto.UUID.generate(),
        "name" => "git_diff",
        "arguments" => %{"paths" => ["lib/greeting.ex"]}
      })

    diff = "diff --git a/lib/greeting.ex b/lib/greeting.ex\n-old\n+hello\n"

    {:ok, _completed} =
      Sessions.append_event(session.id, "tool_completed", %{
        "tool_call_id" => tool_call_id,
        "name" => "git_diff",
        "output" => %{"content" => diff}
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert has_element?(view, "#session-detail")
    assert has_element?(view, "#sessions-#{session.id}[aria-current='page']")
    assert has_element?(view, "#message-form")
    assert has_element?(view, "#send-message")
    assert has_element?(view, "#messages", "Please fix it")
    assert has_element?(view, "#messages", "The fix is ready")
    assert has_element?(view, "#tool-#{tool_call_id}", "git_diff")
    assert has_element?(view, "#changed-files", "lib/greeting.ex")
    assert has_element?(view, "#diff-viewer", "+hello")

    view |> form("#message-form", message: %{content: "   "}) |> render_submit()
    assert has_element?(view, "#flash-error", "Message cannot be empty")
  end

  test "warns when changed files and diff content are truncated", %{
    conn: conn,
    session: session
  } do
    tool_call_id = Ecto.UUID.generate()

    {:ok, _requested} =
      Sessions.append_event(session.id, "tool_requested", %{
        "tool_call_id" => tool_call_id,
        "request_id" => Ecto.UUID.generate(),
        "name" => "git_diff",
        "arguments" => %{"paths" => []}
      })

    {:ok, _completed} =
      Sessions.append_event(session.id, "tool_completed", %{
        "tool_call_id" => tool_call_id,
        "name" => "git_diff",
        "output" => %{
          "content" => "diff --git a/lib/visible.ex b/lib/visible.ex\n+visible\n",
          "truncated" => true
        }
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert has_element?(view, "#diff-truncated-warning")
    assert has_element?(view, "#changed-file-count", "1+")
  end

  test "survives malformed durable git diff output", %{conn: conn, session: session} do
    {:ok, _completed} =
      Sessions.append_event(session.id, "tool_completed", %{
        "tool_call_id" => Ecto.UUID.generate(),
        "name" => "git_diff",
        "output" => "invalid"
      })

    assert {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    assert has_element?(view, "#diff-unavailable-warning")
    assert has_element?(view, "#session-detail")
  end

  test "replays tool activity in durable event order", %{conn: conn, session: session} do
    {:ok, _first} =
      Sessions.append_event(session.id, "tool_requested", %{
        "tool_call_id" => "first",
        "request_id" => "ffffffff-ffff-4fff-8fff-ffffffffffff",
        "name" => "search_code",
        "arguments" => %{"query" => "first", "paths" => []}
      })

    {:ok, between} =
      Sessions.append_event(session.id, "user_message", %{
        "role" => "user",
        "content" => "Between tools"
      })

    {:ok, _second} =
      Sessions.append_event(session.id, "tool_requested", %{
        "tool_call_id" => "second",
        "request_id" => "00000000-0000-4000-8000-000000000000",
        "name" => "read_file",
        "arguments" => %{"path" => "second", "offset" => 0, "limit" => 1}
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert has_element?(view, "#tool-first + #message-#{between.id} + #tool-second")
  end

  test "ignores duplicate and out-of-order event notifications", %{
    conn: conn,
    scope: scope,
    session: session
  } do
    assert {:ok, _status} = Sessions.set_status(session.id, "running")
    tool_call_id = Ecto.UUID.generate()

    {:ok, _requested} =
      Sessions.append_event(session.id, "tool_requested", %{
        "tool_call_id" => tool_call_id,
        "request_id" => Ecto.UUID.generate(),
        "name" => "apply_patch",
        "arguments" => %{"patch" => "patch"}
      })

    approval_id = Ecto.UUID.generate()

    assert {:ok, {approval_requested, _awaiting}} =
             Sessions.request_approval(session.id, %{
               "approval_id" => approval_id,
               "tool_call_id" => tool_call_id,
               "name" => "apply_patch",
               "arguments" => %{"patch" => "patch"},
               "description" => "Apply patch"
             })

    assert {:ok, _resolved} =
             Sessions.resolve_approval(scope, session.id, approval_id, "approved")

    {:ok, tool_started} =
      Sessions.append_event(session.id, "tool_started", %{
        "tool_call_id" => tool_call_id,
        "name" => "apply_patch"
      })

    {:ok, _tool_completed} =
      Sessions.append_event(session.id, "tool_completed", %{
        "tool_call_id" => tool_call_id,
        "name" => "apply_patch",
        "output" => %{"content" => "done"}
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    refute has_element?(view, "#pending-approval")
    assert has_element?(view, "#tool-#{tool_call_id}", "completed")

    send(view.pid, {:session_event, tool_started})
    send(view.pid, {:session_event, approval_requested})

    refute has_element?(view, "#pending-approval")
    assert has_element?(view, "#tool-#{tool_call_id}", "completed")
  end

  test "streams new durable events and survives browser disconnect", %{
    conn: conn,
    session: session
  } do
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    {:ok, event} =
      Sessions.append_event(session.id, "assistant_message_completed", %{
        "role" => "assistant",
        "content" => "Arrived live"
      })

    assert has_element?(view, "#messages", "Arrived live")

    GenServer.stop(view.pid)

    assert {:ok, persisted} =
             Sessions.append_event(session.id, "user_message", %{
               "role" => "user",
               "content" => "CLI remains connected"
             })

    assert persisted.sequence == event.sequence + 1
  end

  test "resolves a pending approval from the browser", %{
    conn: conn,
    scope: scope,
    session: session
  } do
    approval_id = Ecto.UUID.generate()
    assert {:ok, _status} = Sessions.set_status(session.id, "running")

    assert {:ok, _events} =
             Sessions.request_approval(session.id, %{
               "approval_id" => approval_id,
               "tool_call_id" => Ecto.UUID.generate(),
               "name" => "apply_patch",
               "arguments" => %{"patch" => "a bounded patch"},
               "description" => "Apply the greeting patch"
             })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert has_element?(view, "#pending-approval", "Apply the greeting patch")
    assert has_element?(view, "#stop-session")
    view |> element("#approve-action") |> render_click()
    refute has_element?(view, "#pending-approval")

    assert Enum.any?(Sessions.events_after(scope, session.id), fn event ->
             event.type == "approval_resolved" and
               event.payload == %{"approval_id" => approval_id, "decision" => "approved"}
           end)
  end
end
