defmodule Kodo.LLM.SafeReqAdapterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kodo.LLM.SafeReqAdapter

  test "removes operation secrets and untrusted details before error steps" do
    request =
      Req.new(
        method: :post,
        url: "https://api.anthropic.com/v1/messages",
        headers: [{"x-api-key", "operation-secret"}],
        body: ~s({"prompt":"private work"}),
        finch_request: fn request, _finch_request, _finch_name, _options ->
          {request,
           Req.Response.new(
             status: 401,
             headers: [{"x-provider-debug", "operation-secret"}],
             body: %{
               "error" => %{
                 "code" => "invalid_api_key",
                 "message" => "echo operation-secret"
               }
             }
           )}
        end
      )
      |> Req.Request.register_options([:api_key, :provider_options])
      |> Req.Request.put_option(:api_key, "operation-secret")
      |> Req.Request.put_option(:provider_options,
        output_format: %{type: "json_schema"},
        api_key: "nested-operation-secret"
      )

    {scrubbed_request, response} =
      capture_io(:stderr, fn ->
        send(self(), {:result, run_for("anthropic", request)})
      end)
      |> then(fn _output ->
        assert_receive {:result, result}
        result
      end)

    assert scrubbed_request.body == nil
    assert Req.Request.get_header(scrubbed_request, "x-api-key") == []
    refute Map.has_key?(scrubbed_request.options, :api_key)

    assert scrubbed_request.options.provider_options == [
             output_format: %{type: "json_schema"}
           ]

    assert response.headers == Req.Fields.new([])
    assert response.body == %{"error" => %{"code" => "invalid_api_key"}}
    refute inspect({scrubbed_request, response}) =~ "operation-secret"
    refute inspect({scrubbed_request, response}) =~ "private work"
  end

  test "redacts an echoed credential from successful provider output" do
    request =
      Req.new(
        method: :post,
        url: "https://api.openai.com/v1/responses",
        headers: [{"authorization", "Bearer operation-secret"}],
        body: "request",
        finch_request: fn request, _finch_request, _finch_name, _options ->
          {request,
           Req.Response.new(
             status: 200,
             body: %{"output" => [%{"content" => "echo operation-secret"}]}
           )}
        end
      )

    {_request, response} =
      capture_io(:stderr, fn -> send(self(), {:result, run_for("openai", request)}) end)
      |> then(fn _output ->
        assert_receive {:result, result}
        result
      end)

    assert response.body == %{"output" => [%{"content" => "echo [REDACTED]"}]}
  end

  test "normalizes transport exceptions without retaining their details" do
    request =
      Req.new(
        method: :post,
        url: "https://api.openai.com/v1/responses",
        headers: [{"authorization", "Bearer operation-secret"}],
        body: "private work",
        finch_request: fn request, _finch_request, _finch_name, _options ->
          {request, Req.TransportError.exception(reason: :econnrefused)}
        end
      )

    {scrubbed_request, error} =
      capture_io(:stderr, fn -> send(self(), {:result, run_for("openai", request)}) end)
      |> then(fn _output ->
        assert_receive {:result, result}
        result
      end)

    assert %Kodo.LLM.SafeTransportError{reason: :network} = error
    refute inspect({scrubbed_request, error}) =~ "operation-secret"
    refute inspect({scrubbed_request, error}) =~ "private work"
  end

  test "classifies all Mint transport failures as retryable network errors" do
    for reason <- [:econnreset, :enetunreach] do
      request =
        Req.new(
          method: :post,
          url: "https://api.openai.com/v1/responses",
          finch_request: fn request, _finch_request, _finch_name, _options ->
            {request, %Mint.TransportError{reason: reason}}
          end
        )

      {_request, error} = run_for("openai", request)
      assert %Kodo.LLM.SafeTransportError{reason: :network} = error
    end
  end

  test "rejects an alternate initial origin before dispatch" do
    test_pid = self()

    request =
      Req.new(
        method: :post,
        url: "https://attacker.example/v1/responses",
        headers: [{"authorization", "Bearer operation-secret"}],
        body: "private work",
        finch_request: fn request, _finch_request, _finch_name, _options ->
          send(test_pid, :dispatched)
          {request, Req.Response.new(status: 200, body: %{})}
        end
      )

    {scrubbed_request, error} = run_for("openai", request)

    assert %Kodo.LLM.SafeTransportError{reason: :invalid_origin} = error
    refute_receive :dispatched
    refute inspect({scrubbed_request, error}) =~ "operation-secret"
    refute inspect({scrubbed_request, error}) =~ "private work"
  end

  defp run_for(provider, request),
    do: SafeReqAdapter.run(request, provider)
end
