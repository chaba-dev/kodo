defmodule KodoWeb.AgentSessionControllerTest do
  use KodoWeb.ConnCase, async: true

  import Kodo.AccountsFixtures

  setup do
    user = user_fixture() |> set_password()
    %{user: user}
  end

  test "issues a bearer token for valid credentials", %{conn: conn, user: user} do
    response =
      conn
      |> post_json(~p"/api/auth/token", %{
        email: user.email,
        password: valid_user_password()
      })
      |> json_response(200)

    assert response["token_type"] == "Bearer"
    assert response["expires_in"] == 2_592_000
    assert Kodo.Accounts.get_user_by_agent_token(response["token"]).id == user.id
  end

  test "rejects invalid or incomplete credentials", %{conn: conn, user: user} do
    assert conn
           |> post_json(~p"/api/auth/token", %{email: user.email, password: "incorrect"})
           |> json_response(401) == %{"error" => "invalid email or password"}

    assert build_conn()
           |> post_json(~p"/api/auth/token", %{email: user.email})
           |> json_response(422) == %{"error" => "email and password are required"}
  end

  test "revokes the presented token", %{conn: conn, user: user} do
    token = Kodo.Accounts.generate_user_agent_token(user)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> delete(~p"/api/auth/token")
           |> response(204)

    refute Kodo.Accounts.get_user_by_agent_token(token)
  end

  test "protected API routes require a valid bearer token", %{conn: conn} do
    conn = get(conn, ~p"/api/sessions/not-a-uuid")
    assert json_response(conn, 401) == %{"error" => "authentication required"}
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
  end

  defp post_json(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end
end
