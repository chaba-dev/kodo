defmodule KodoWeb.PageControllerTest do
  use KodoWeb.ConnCase

  alias Kodo.Runners
  alias Kodo.Sessions

  import Kodo.AccountsFixtures

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end

  test "authenticated browser handoff shows an owned session", %{conn: conn} do
    user = user_fixture()
    scope = Kodo.Accounts.Scope.for_user(user)

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
        title: "CLI handoff",
        model: "test:model"
      })

    conn = conn |> log_in_user(user) |> get(~p"/sessions/#{session.id}")

    assert html_response(conn, 200)
    assert conn.resp_body =~ "CLI handoff"
    assert conn.resp_body =~ "kodo resume #{session.id}"
  end

  test "browser handoff requires login", %{conn: conn} do
    id = Ecto.UUID.generate()
    conn = get(conn, ~p"/sessions/#{id}")
    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
