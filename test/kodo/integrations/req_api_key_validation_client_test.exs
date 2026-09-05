defmodule Kodo.Integrations.ReqAPIKeyValidationClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kodo.Integrations.ReqAPIKeyValidationClient

  test "sends provider credentials only to their fixed HTTPS metadata endpoints" do
    for {provider, host, path, expected_headers} <- [
          {"openai", "api.openai.com", "/v1/models",
           %{"authorization" => ["Bearer fixed-origin-secret"]}},
          {"anthropic", "api.anthropic.com", "/v1/models",
           %{
             "anthropic-version" => ["2023-06-01"],
             "x-api-key" => ["fixed-origin-secret"]
           }},
          {"openrouter", "openrouter.ai", "/api/v1/key",
           %{"authorization" => ["Bearer fixed-origin-secret"]}}
        ] do
      plug = fn conn ->
        assert conn.scheme == :https
        assert conn.host == host
        assert conn.request_path == path

        for {header, expected} <- expected_headers do
          assert Plug.Conn.get_req_header(conn, header) == expected
        end

        Req.Test.json(conn, %{"data" => []})
      end

      assert {:ok, 200, %{"data" => []}} =
               ReqAPIKeyValidationClient.get_metadata(provider, "fixed-origin-secret", plug: plug)
    end
  end

  test "does not follow same-origin or cross-origin redirects" do
    for location <- [
          "https://api.openai.com/v1/other-models",
          "https://attacker.example/collect"
        ] do
      counter = start_supervised!({Agent, fn -> 0 end}, id: {:request_counter, location})

      plug = fn conn ->
        Agent.update(counter, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_header("location", location)
        |> Plug.Conn.send_resp(302, "redirect")
      end

      assert {:error, :redirect} =
               ReqAPIKeyValidationClient.get_metadata("openai", "redirect-secret", plug: plug)

      assert Agent.get(counter, & &1) == 1
    end
  end

  test "builds the production Finch request with bounded transport options" do
    test_pid = self()

    finch_request = fn request, finch_request, _finch_name, options ->
      send(test_pid, {:finch_request, finch_request, options})
      {request, %Req.Response{status: 200, body: %{"data" => []}}}
    end

    capture_io(:stderr, fn ->
      assert {:ok, 200, %{"data" => []}} =
               ReqAPIKeyValidationClient.get_metadata("openai", "finch-options-secret",
                 finch_request: finch_request
               )
    end)

    assert_receive {:finch_request, request, options}
    assert request.host == "api.openai.com"
    assert options[:pool_timeout] == 5_000
    assert options[:receive_timeout] == 5_000
    assert options[:request_timeout] == 5_000
  end

  test "normalizes Finch's pool checkout exception" do
    finch_request = fn _request, _finch_request, _finch_name, _options ->
      raise "Finch was unable to provide a connection within the timeout due to excess queuing"
    end

    capture_io(:stderr, fn ->
      assert {:error, :timeout} =
               ReqAPIKeyValidationClient.get_metadata("openai", "pool-timeout-secret",
                 finch_request: finch_request
               )
    end)
  end

  test "does not retry provider failures" do
    counter = start_supervised!({Agent, fn -> 0 end})

    plug = fn conn ->
      Agent.update(counter, &(&1 + 1))

      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => "unavailable"})
    end

    assert {:ok, 503, %{"error" => "unavailable"}} =
             ReqAPIKeyValidationClient.get_metadata("openai", "no-retry-secret", plug: plug)

    assert Agent.get(counter, & &1) == 1
  end
end
