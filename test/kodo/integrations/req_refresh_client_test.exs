defmodule Kodo.Integrations.ReqRefreshClientTest do
  use ExUnit.Case, async: true

  alias Kodo.Integrations.ReqRefreshClient

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"

  test "refreshes at the pinned endpoint with the published contract" do
    plug = fn conn ->
      assert conn.method == "POST"
      assert conn.scheme == :https
      assert conn.host == "auth.openai.com"
      assert conn.request_path == "/oauth/token"

      assert json_body(conn) == %{
               "client_id" => @client_id,
               "grant_type" => "refresh_token",
               "refresh_token" => "refresh-secret"
             }

      Req.Test.json(conn, %{
        "access_token" => "access-secret",
        "refresh_token" => "rotated-secret",
        "id_token" => "identity-secret"
      })
    end

    assert {:ok, %{"access_token" => "access-secret"}} =
             ReqRefreshClient.refresh("refresh-secret", plug: plug)
  end

  test "classifies the pinned permanent refresh failures as invalid credentials" do
    invalid_grant = fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
    end

    assert {:error, :invalid_grant} =
             ReqRefreshClient.refresh("refresh-secret", plug: invalid_grant)

    for {status, body} <- [
          {401, %{"code" => "token_expired"}},
          {400, %{"code" => "refresh_token_expired"}},
          {400, %{"code" => "refresh_token_reused"}},
          {400, %{"code" => "refresh_token_invalidated"}}
        ] do
      plug = fn conn -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body) end

      assert {:error, :invalid_grant} =
               ReqRefreshClient.refresh("refresh-secret", plug: plug)
    end

    for body <- [%{"error" => "temporarily_unavailable"}, %{"message" => "invalid_grant"}] do
      plug = fn conn -> conn |> Plug.Conn.put_status(400) |> Req.Test.json(body) end

      assert {:error, :provider_unavailable} =
               ReqRefreshClient.refresh("refresh-secret", plug: plug)
    end
  end

  test "rejects redirects, malformed success, and unsafe caller input with bounded errors" do
    redirect = fn conn -> Plug.Conn.send_resp(conn, 302, "private") end
    malformed = fn conn -> Req.Test.json(conn, %{"refresh_token" => "private"}) end

    assert {:error, :redirect} = ReqRefreshClient.refresh("refresh-secret", plug: redirect)

    assert {:error, :oauth_refresh_response_invalid} =
             ReqRefreshClient.refresh("refresh-secret", plug: malformed)

    assert {:error, :oauth_refresh_response_invalid} = ReqRefreshClient.refresh("")
    assert {:error, :oauth_refresh_response_invalid} = ReqRefreshClient.refresh(:secret)
  end

  test "uses the credential transport without emitting Finch telemetry" do
    test_pid = self()
    handler_id = "refresh-finch-canary-#{System.unique_integer()}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:finch, :request, :start], [:finch, :request, :stop], [:finch, :request, :exception]],
        fn event, measurements, metadata, pid ->
          send(pid, {:finch_telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    transport = fn request, _started_at, _timeout ->
      assert IO.iodata_to_binary(request.body) =~ "refresh-secret"

      {request,
       Req.Response.new(status: 200, body: Jason.encode!(%{"access_token" => "access-secret"}))}
    end

    assert {:ok, _tokens} =
             ReqRefreshClient.refresh("refresh-secret", credential_request_transport: transport)

    refute_receive {:finch_telemetry, _event, _measurements, _metadata}
  end

  defp json_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end
end
