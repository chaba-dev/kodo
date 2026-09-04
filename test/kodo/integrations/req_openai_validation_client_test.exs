defmodule Kodo.Integrations.ReqOpenAIValidationClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kodo.Integrations.ReqOpenAIValidationClient

  test "sends the key only to the fixed OpenAI HTTPS models endpoint" do
    secret = "fixed-origin-secret"

    plug = fn conn ->
      assert conn.scheme == :https
      assert conn.host == "api.openai.com"
      assert conn.request_path == "/v1/models"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{secret}"]
      Req.Test.json(conn, %{"data" => []})
    end

    assert {:ok, 200, %{"data" => []}} =
             ReqOpenAIValidationClient.get_models(secret, plug: plug)
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
               ReqOpenAIValidationClient.get_models("redirect-secret", plug: plug)

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
               ReqOpenAIValidationClient.get_models("finch-options-secret",
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
               ReqOpenAIValidationClient.get_models("pool-timeout-secret",
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
             ReqOpenAIValidationClient.get_models("no-retry-secret", plug: plug)

    assert Agent.get(counter, & &1) == 1
  end
end
