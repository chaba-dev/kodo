defmodule Kodo.Integrations.ReqDeviceAuthorizationClientTest do
  use ExUnit.Case, async: true

  alias Kodo.Integrations.ReqDeviceAuthorizationClient

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"

  test "creates a device code at the pinned origin and preserves the exact interval" do
    plug = fn conn ->
      assert_request(conn, "/api/accounts/deviceauth/usercode")
      assert json_body(conn) == %{"client_id" => @client_id}

      Req.Test.json(conn, %{
        "device_auth_id" => "device-secret",
        "user_code" => "ABCD-EFGH",
        "interval" => "0"
      })
    end

    assert {:ok,
            %{
              payload: %{
                "device_auth_id" => "device-secret",
                "user_code" => "ABCD-EFGH"
              },
              polling_interval_ms: 0,
              verification_url: "https://auth.openai.com/codex/device"
            }} = ReqDeviceAuthorizationClient.create(plug: plug)
  end

  test "accepts the published usercode alias and an exact verification destination" do
    plug = fn conn ->
      Req.Test.json(conn, %{
        "device_auth_id" => "device",
        "usercode" => "CODE",
        "interval" => " 5 ",
        "verification_uri" => "https://auth.openai.com/codex/device"
      })
    end

    assert {:ok, %{payload: %{"user_code" => "CODE"}, polling_interval_ms: 5_000}} =
             ReqDeviceAuthorizationClient.create(plug: plug)
  end

  test "rejects response-selected verification destinations and malformed creation fields" do
    invalid_bodies = [
      %{"device_auth_id" => "device", "user_code" => "CODE", "interval" => 5},
      %{"device_auth_id" => "device", "user_code" => "CODE", "interval" => "-1"},
      %{"device_auth_id" => "device", "user_code" => "CODE", "interval" => "901"},
      %{
        "device_auth_id" => "device",
        "user_code" => "CODE",
        "interval" => "5",
        "verification_url" => "https://attacker.example/collect"
      }
    ]

    for body <- invalid_bodies do
      plug = fn conn -> Req.Test.json(conn, body) end

      assert {:error, :device_authorization_response_invalid} =
               ReqDeviceAuthorizationClient.create(plug: plug)
    end
  end

  test "polls the pinned endpoint and classifies only 403 and 404 as pending" do
    payload = %{"device_auth_id" => "device-secret", "user_code" => "CODE"}

    for status <- [403, 404] do
      plug = fn conn ->
        assert_request(conn, "/api/accounts/deviceauth/token")
        assert json_body(conn) == payload
        Plug.Conn.send_resp(conn, status, "pending")
      end

      assert :pending = ReqDeviceAuthorizationClient.poll(payload, plug: plug)
    end

    for status <- [400, 401, 429, 500] do
      plug = fn conn -> Plug.Conn.send_resp(conn, status, "private provider detail") end

      assert {:error, :device_authorization_rejected} =
               ReqDeviceAuthorizationClient.poll(payload, plug: plug)
    end
  end

  test "decodes the complete authorization-code polling response" do
    plug = fn conn ->
      Req.Test.json(conn, %{
        "authorization_code" => "authorization-secret",
        "code_challenge" => "challenge-secret",
        "code_verifier" => "verifier-secret"
      })
    end

    assert {:ok,
            %{
              "authorization_code" => "authorization-secret",
              "code_challenge" => "challenge-secret",
              "code_verifier" => "verifier-secret"
            }} =
             ReqDeviceAuthorizationClient.poll(
               %{"device_auth_id" => "device", "user_code" => "CODE"},
               plug: plug
             )
  end

  test "exchanges the authorization code with the pinned form contract" do
    plug = fn conn ->
      assert_request(conn, "/oauth/token")

      assert URI.decode_query(request_body(conn)) == %{
               "client_id" => @client_id,
               "code" => "authorization-secret",
               "code_verifier" => "verifier-secret",
               "grant_type" => "authorization_code",
               "redirect_uri" => "https://auth.openai.com/deviceauth/callback"
             }

      Req.Test.json(conn, %{
        "access_token" => "access-secret",
        "refresh_token" => "refresh-secret",
        "id_token" => "identity-secret"
      })
    end

    assert {:ok,
            %{
              "access_token" => "access-secret",
              "refresh_token" => "refresh-secret",
              "id_token" => "identity-secret"
            }} =
             ReqDeviceAuthorizationClient.exchange(
               %{
                 "authorization_code" => "authorization-secret",
                 "code_verifier" => "verifier-secret"
               },
               plug: plug
             )
  end

  test "requires every initial token and returns no private response details on failure" do
    sentinel = "private-provider-detail"

    for body <- [
          %{"access_token" => "access", "refresh_token" => "refresh"},
          %{"access_token" => "", "refresh_token" => "refresh", "id_token" => "identity"}
        ] do
      plug = fn conn -> Req.Test.json(conn, body) end
      assert result = {:error, :device_authorization_response_invalid}

      assert ^result =
               ReqDeviceAuthorizationClient.exchange(
                 %{"authorization_code" => "code", "code_verifier" => "verifier"},
                 plug: plug
               )

      refute inspect(result) =~ sentinel
    end

    plug = fn conn -> Plug.Conn.send_resp(conn, 400, sentinel) end
    assert result = {:error, :device_authorization_rejected}

    assert ^result =
             ReqDeviceAuthorizationClient.exchange(
               %{"authorization_code" => "code", "code_verifier" => "verifier"},
               plug: plug
             )

    refute inspect(result) =~ sentinel
  end

  test "never follows redirects or retries provider responses" do
    counter = start_supervised!({Agent, fn -> 0 end})

    plug = fn conn ->
      Agent.update(counter, &(&1 + 1))

      conn
      |> Plug.Conn.put_resp_header("location", "https://attacker.example/collect")
      |> Plug.Conn.send_resp(302, "redirect")
    end

    assert {:error, :redirect} = ReqDeviceAuthorizationClient.create(plug: plug)
    assert Agent.get(counter, & &1) == 1
  end

  test "maps transport failures to one bounded availability error" do
    finch_request = fn request, _finch_request, _finch_name, _options ->
      {request, %Req.TransportError{reason: :econnrefused}}
    end

    assert {:error, :provider_unavailable} =
             ReqDeviceAuthorizationClient.create(finch_request: finch_request)
  end

  defp assert_request(conn, path) do
    assert conn.method == "POST"
    assert conn.scheme == :https
    assert conn.host == "auth.openai.com"
    assert conn.request_path == path
  end

  defp json_body(conn), do: conn |> request_body() |> Jason.decode!()

  defp request_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    body
  end
end
