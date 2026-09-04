defmodule Kodo.Integrations.ReqOpenAIValidationClientTest do
  use ExUnit.Case, async: true

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

  test "normalizes a transport pool checkout exit" do
    plug = fn _conn -> exit({:timeout, {NimblePool, :checkout, []}}) end

    assert {:error, :network_error} =
             ReqOpenAIValidationClient.get_models("pool-timeout-secret", plug: plug)
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
