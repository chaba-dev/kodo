defmodule KodoWeb.AgentSessionController do
  @moduledoc "Issues and revokes bearer tokens for non-browser agent clients."

  use KodoWeb, :controller

  alias Kodo.Accounts

  def create(conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    case Accounts.get_user_by_email_and_password(email, password) do
      %{confirmed_at: confirmed_at} = user when not is_nil(confirmed_at) ->
        json(conn, %{
          token: Accounts.generate_user_agent_token(user),
          token_type: "Bearer",
          expires_in: Accounts.agent_token_validity_in_seconds()
        })

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid email or password"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "email and password are required"})
  end

  def delete(conn, _params) do
    :ok = Accounts.delete_user_agent_token(conn.assigns.current_agent_token)
    send_resp(conn, :no_content, "")
  end
end
