defmodule KodoWeb.AgentSessionControllerTest do
  use KodoWeb.ConnCase, async: true

  import Ecto.Query
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

  test "rejects non-string credentials", %{user: user} do
    for credentials <- [
          %{email: nil, password: valid_user_password()},
          %{email: user.email, password: %{value: valid_user_password()}},
          %{email: [user.email], password: valid_user_password()},
          %{email: user.email, password: 12_345}
        ] do
      assert build_conn()
             |> post_json(~p"/api/auth/token", credentials)
             |> json_response(422) == %{"error" => "email and password are required"}
    end
  end

  test "rejects an unconfirmed account with a password", %{conn: conn} do
    user = unconfirmed_user_fixture() |> set_password()

    assert conn
           |> post_json(~p"/api/auth/token", %{
             email: user.email,
             password: valid_user_password()
           })
           |> json_response(401) == %{"error" => "invalid email or password"}

    token = Kodo.Accounts.generate_user_agent_token(user)

    assert build_conn()
           |> put_req_header("authorization", "Bearer #{token}")
           |> get(~p"/api/sessions/not-a-uuid")
           |> json_response(401) == %{"error" => "authentication required"}
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

  test "accepts the case-insensitive Bearer scheme and flexible separating whitespace", %{
    user: user
  } do
    lowercase_token = Kodo.Accounts.generate_user_agent_token(user)
    spaced_token = Kodo.Accounts.generate_user_agent_token(user)

    for authorization <- ["bearer #{lowercase_token}", "BEARER   #{spaced_token}"] do
      assert build_conn()
             |> put_req_header("authorization", authorization)
             |> delete(~p"/api/auth/token")
             |> response(204)
    end
  end

  test "rejects blank, malformed, and duplicate bearer credentials", %{user: user} do
    token = Kodo.Accounts.generate_user_agent_token(user)

    authorizations = [
      [{"authorization", "Bearer"}],
      [{"authorization", "Bearer not-base64!"}],
      [{"authorization", "Bearer #{token}"}, {"authorization", "Bearer #{token}"}]
    ]

    for headers <- authorizations do
      assert build_conn()
             |> prepend_req_headers(headers)
             |> delete(~p"/api/auth/token")
             |> json_response(401) == %{"error" => "authentication required"}
    end
  end

  test "rejects expired and revoked bearer tokens", %{user: user} do
    expired_token = Kodo.Accounts.generate_user_agent_token(user)
    {:ok, expired_hash} = Kodo.Accounts.UserToken.agent_token_hash(expired_token)

    Kodo.Repo.update_all(
      from(token in Kodo.Accounts.UserToken, where: token.token == ^expired_hash),
      set: [inserted_at: ~N[2020-01-01 00:00:00]]
    )

    revoked_token = Kodo.Accounts.generate_user_agent_token(user)
    :ok = Kodo.Accounts.delete_user_agent_token(revoked_token)

    for token <- [expired_token, revoked_token] do
      assert build_conn()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(~p"/api/sessions/not-a-uuid")
             |> json_response(401) == %{"error" => "authentication required"}
    end
  end

  defp post_json(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end
end
