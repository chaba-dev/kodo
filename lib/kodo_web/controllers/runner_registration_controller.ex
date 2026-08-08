defmodule KodoWeb.RunnerRegistrationController do
  @moduledoc "Issues short-lived runner credentials through the local-only bootstrap endpoint."

  use KodoWeb, :controller

  alias Kodo.RunnerProtocol
  alias Kodo.Runners

  @protocol_version RunnerProtocol.version()
  @token_salt RunnerProtocol.token_salt()
  @token_max_age_seconds RunnerProtocol.token_max_age_seconds()

  def create(conn, params) do
    # Registration is intentionally an unauthenticated bootstrap boundary limited to this host.
    cond do
      not json_request?(conn) ->
        conn |> put_status(:unsupported_media_type) |> json(%{error: "JSON body required"})

      not loopback?(conn.remote_ip) ->
        conn |> put_status(:forbidden) |> json(%{error: "loopback access required"})

      true ->
        case Runners.register(params) do
          {:ok, runner} ->
            token = Phoenix.Token.sign(KodoWeb.Endpoint, @token_salt, runner.id)

            json(conn, %{
              runner_id: runner.id,
              token: token,
              token_expires_in: @token_max_age_seconds,
              socket_path: "/runner/websocket",
              topic: "runner:#{runner.id}",
              protocol_version: @protocol_version
            })

          {:error, changeset} ->
            conn |> put_status(:unprocessable_entity) |> json(%{errors: errors(changeset)})
        end
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, text ->
        String.replace(text, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp json_request?(conn) do
    conn
    |> get_req_header("content-type")
    |> Enum.any?(&String.starts_with?(&1, "application/json"))
  end
end
