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
        Plug.Conn.send_resp(conn, status, "{malformed private pending response")
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
      Plug.Conn.send_resp(conn, 302, "redirect without a location")
    end

    payloads = [
      {&ReqDeviceAuthorizationClient.create/1, []},
      {&ReqDeviceAuthorizationClient.poll/2,
       [%{"device_auth_id" => "device", "user_code" => "code"}]},
      {&ReqDeviceAuthorizationClient.exchange/2,
       [%{"authorization_code" => "auth", "code_verifier" => "verifier"}]}
    ]

    for {operation, arguments} <- payloads do
      assert {:error, :redirect} = apply(operation, arguments ++ [[plug: plug]])
    end

    assert Agent.get(counter, & &1) == 3
  end

  test "maps transport failures to one bounded availability error" do
    transport = fn request, _started_at, _timeout ->
      {request, %Req.TransportError{reason: :econnrefused}}
    end

    assert {:error, :provider_unavailable} =
             ReqDeviceAuthorizationClient.create(device_authorization_transport: transport)
  end

  test "accepts device fields at 1024 bytes and rejects 1025 bytes" do
    for field <- ["device_auth_id", "user_code"] do
      for {size, expected} <- [{1_024, :ok}, {1_025, :error}] do
        body = %{
          "device_auth_id" => "device",
          "user_code" => "code",
          "interval" => "5",
          field => String.duplicate("x", size)
        }

        plug = fn conn -> Req.Test.json(conn, body) end
        result = ReqDeviceAuthorizationClient.create(plug: plug)
        assert elem(result, 0) == expected
      end
    end
  end

  test "accepts authorization fields at 8192 bytes and rejects 8193 bytes" do
    for size <- [8_192, 8_193] do
      plug = fn conn ->
        Req.Test.json(conn, %{
          "authorization_code" => String.duplicate("a", size),
          "code_challenge" => "challenge",
          "code_verifier" => "verifier"
        })
      end

      result =
        ReqDeviceAuthorizationClient.poll(
          %{"device_auth_id" => "device", "user_code" => "code"},
          plug: plug
        )

      assert elem(result, 0) == if(size == 8_192, do: :ok, else: :error)
    end
  end

  test "production adapter emits no Finch telemetry containing protocol secrets" do
    sentinel = "SENTINEL-device-code-token-response"
    test_pid = self()
    handler_id = "device-auth-finch-canary-#{System.unique_integer()}"

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
      assert IO.iodata_to_binary(request.body) =~ sentinel

      {request,
       Req.Response.new(
         status: 200,
         body:
           Jason.encode!(%{
             "authorization_code" => sentinel,
             "code_challenge" => "challenge",
             "code_verifier" => "verifier"
           })
       )}
    end

    assert {:ok, %{"authorization_code" => ^sentinel}} =
             ReqDeviceAuthorizationClient.poll(
               %{"device_auth_id" => sentinel, "user_code" => sentinel},
               device_authorization_transport: transport
             )

    refute_receive {:finch_telemetry, _event, _measurements, _metadata}
  end

  test "hard deadline terminates transport work" do
    test_pid = self()

    transport = fn request, _started_at, _timeout ->
      try do
        send(test_pid, :transport_started)

        receive do
          :finish_transport -> :ok
        end

        {request, Req.Response.new(status: 500, body: "private")}
      after
        send(test_pid, :transport_completed)
      end
    end

    assert {:error, :provider_unavailable} =
             ReqDeviceAuthorizationClient.create(
               device_authorization_transport: transport,
               device_authorization_timeout: 10
             )

    assert_received :transport_started
    refute_receive :transport_completed
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
