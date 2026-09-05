defmodule Kodo.LLM.SafeReqAdapter do
  @moduledoc """
  Scrubs provider HTTP results before ReqLLM can observe them.

  ReqLLM's terminal-error telemetry retains its input error, while Finch emits
  request telemetry before a wrapping Req adapter can scrub it. Kodo therefore
  uses Req with this Mint-backed adapter, validates the final provider origin,
  and removes operation-local secrets and untrusted error details before
  ReqLLM's response, logging, and telemetry steps execute. Only documented
  identifiers needed for safe classification are retained from failures.
  """

  @credential_option_keys ~w(api_key access_token auth_mode oauth_file auth_file chatgpt_account_id)a
  @credential_headers ~w(authorization x-api-key chatgpt-account-id)
  @provider_origins %{
    "openai" => {"https", "api.openai.com", 443},
    "openai_codex" => {"https", "chatgpt.com", 443},
    "anthropic" => {"https", "api.anthropic.com", 443},
    "openrouter" => {"https", "openrouter.ai", 443}
  }
  @allow_test_origins Application.compile_env(:kodo, :allow_test_provider_origins, false)
  @default_timeout 15_000
  @max_response_bytes 16 * 1024 * 1024
  @safe_error_codes [
    401,
    402,
    429,
    "invalid_api_key",
    "key_revoked",
    "credit_balance_exhausted",
    "organization_spend_limit_exceeded",
    "project_spend_limit_exceeded"
  ]
  @openai_tool_usage_bases ~w(
    web_search web_search_preview file_search mcp x_search code_interpreter
  )
  @max_tool_usage_count 1_000_000
  @safe_error_types ~w(authentication_error billing_error permission_error rate_limit_error invalid_request_error)
  @anthropic_workspace_required_message "anthropic-workspace-id is required when authenticating with an identity-linked API key"
  @anthropic_spend_limit_prefixes [
    "You have reached your specified API usage limits",
    "You have reached your specified workspace API usage limits"
  ]

  def run(%Req.Request{} = request) do
    run(request, nil)
  end

  def run(%Req.Request{} = request, provider) do
    secrets = credential_values(request)

    case validate_origin(request, provider) do
      :ok ->
        request
        |> perform_request()
        |> sanitize_result(secrets, provider)

      {:error, reason} ->
        {scrub_request(request), Kodo.LLM.SafeTransportError.exception(reason: reason)}
    end
  end

  defp perform_request(%Req.Request{options: %{finch_request: fun}} = request)
       when is_function(fun) do
    # Req's deprecated Finch callback remains a test-only transport seam. It
    # returns before Finch emits request telemetry, so no request is dispatched.
    Req.Finch.run(request)
  end

  defp perform_request(request) do
    # Decoding must happen before untrusted response data can enter ReqLLM's
    # error pipeline, so ask providers for an uncompressed JSON body here.
    request = Req.Request.delete_header(request, "accept-encoding")
    url = request.url
    timeout = request.options[:receive_timeout] || @default_timeout
    connect_timeout = get_in(request.options, [:connect_options, :timeout]) || timeout

    case Mint.HTTP.connect(
           String.to_existing_atom(url.scheme),
           url.host,
           url.port || default_port(url.scheme),
           mode: :passive,
           protocols: [:http1],
           transport_opts: [timeout: connect_timeout]
         ) do
      {:ok, conn} -> send_request(request, conn, timeout)
      {:error, reason} -> {request, safe_mint_error(reason)}
    end
  end

  defp send_request(request, conn, timeout) do
    method = request.method |> to_string() |> String.upcase()
    path = URI.to_string(%{request.url | scheme: nil, host: nil, port: nil, userinfo: nil})
    headers = Req.Fields.get_list(request.headers)

    case Mint.HTTP.request(conn, method, path, headers, request.body) do
      {:ok, conn, ref} -> receive_response(request, conn, ref, timeout, empty_response())
      {:error, conn, reason} -> close_with_error(request, conn, reason)
    end
  end

  defp receive_response(request, conn, ref, timeout, response) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, entries} ->
        case collect_response(entries, ref, response) do
          {:cont, response} -> receive_response(request, conn, ref, timeout, response)
          {:done, response} -> close_with_response(request, conn, response)
          {:error, reason} -> close_with_error(request, conn, reason)
        end

      {:error, conn, reason, entries} ->
        case collect_response(entries, ref, response) do
          {:done, response} -> close_with_response(request, conn, response)
          _other -> close_with_error(request, conn, reason)
        end
    end
  end

  defp collect_response(entries, ref, response) do
    Enum.reduce_while(entries, {:cont, response}, fn
      {:status, ^ref, status}, {:cont, acc} ->
        {:cont, {:cont, %{acc | status: status}}}

      {:headers, ^ref, headers}, {:cont, acc} ->
        {:cont, {:cont, %{acc | headers: acc.headers ++ headers}}}

      {:data, ^ref, data}, {:cont, acc} ->
        size = acc.size + byte_size(data)

        if size <= @max_response_bytes,
          do: {:cont, {:cont, %{acc | body: [data | acc.body], size: size}}},
          else: {:halt, {:error, :response_too_large}}

      {:done, ^ref}, {:cont, acc} ->
        {:halt, {:done, acc}}

      {:error, ^ref, reason}, {:cont, _acc} ->
        {:halt, {:error, reason}}

      _other, result ->
        {:cont, result}
    end)
  end

  defp close_with_response(request, conn, response) do
    {:ok, _conn} = Mint.HTTP.close(conn)

    body = response.body |> Enum.reverse() |> IO.iodata_to_binary()

    {request,
     Req.Response.new(
       status: response.status,
       headers: response.headers,
       body: body
     )}
  end

  defp close_with_error(request, conn, reason) do
    {:ok, _conn} = Mint.HTTP.close(conn)
    {request, safe_mint_error(reason)}
  end

  defp empty_response, do: %{status: nil, headers: [], body: [], size: 0}

  defp sanitize_result({request, %Req.Response{status: status} = response}, secrets, provider)
       when status in 200..299 do
    case decode_success(request, response, provider) do
      {:ok, response} ->
        request = request |> scrub_request() |> protect_response_decoding()
        {request, sanitize_success(response, provider, secrets)}

      {:error, reason} ->
        {scrub_request(request), safe_transport_error(reason)}
    end
  end

  defp sanitize_result({request, %Req.Response{} = response}, _secrets, _provider),
    do: {scrub_request(request), scrub_error_response(response)}

  defp sanitize_result({request, exception}, _secrets, _provider) when is_exception(exception),
    do: {scrub_request(request), safe_transport_error(exception)}

  # ReqLLM owns provider decoders after the adapter returns. Wrap those steps so
  # a future decoder exception cannot reintroduce an untrusted body into its
  # error telemetry; this compatibility fence can go when ReqLLM bounds errors.
  defp protect_response_decoding(request) do
    steps =
      Enum.map(request.response_steps, fn
        {name, step} when is_function(step, 1) ->
          {name,
           fn request_and_response -> run_safe_response_step(step, request_and_response) end}

        step ->
          step
      end)

    %{request | response_steps: steps}
  end

  defp run_safe_response_step(step, {%Req.Request{} = request, %Req.Response{}} = input) do
    case step.(input) do
      {%Req.Request{} = request, exception} when is_exception(exception) ->
        {scrub_request(request), safe_transport_error(exception)}

      result ->
        result
    end
  rescue
    _exception -> {scrub_request(request), safe_transport_error(:response_decoding)}
  catch
    _kind, _reason -> {scrub_request(request), safe_transport_error(:response_decoding)}
  end

  defp credential_values(request) do
    @credential_headers
    |> Enum.flat_map(&Req.Request.get_header(request, &1))
    |> Enum.map(&String.replace_prefix(&1, "Bearer ", ""))
    |> Enum.reject(&(&1 == ""))
  end

  defp scrub_request(request) do
    request = Enum.reduce(@credential_headers, request, &Req.Request.delete_header(&2, &1))

    options =
      request.options
      |> Map.drop(@credential_option_keys)
      |> Map.update(:provider_options, nil, &scrub_provider_options/1)

    %{request | body: nil, options: options}
  end

  defp scrub_provider_options(options) when is_list(options) do
    Enum.reject(options, fn {key, _value} -> key in @credential_option_keys end)
  end

  defp scrub_provider_options(options) when is_map(options),
    do: Map.drop(options, @credential_option_keys)

  defp scrub_provider_options(_options), do: nil

  defp sanitize_success(%Req.Response{body: body} = response, provider, secrets) do
    %{
      response
      | body: body |> sanitize_provider_success(provider) |> redact(secrets),
        headers: Req.Fields.new([]),
        trailers: Req.Fields.new([])
    }
  end

  # ReqLLM 1.19 preserves unknown OpenAI server-tool usage keys in telemetry.
  # Keep only reviewed identifiers until that dependency bounds them itself.
  defp sanitize_provider_success(body, "openai") when is_map(body) do
    if is_map(body["usage"]) do
      Map.update!(body, "usage", fn usage ->
        usage
        |> sanitize_usage_map("server_side_tool_usage_details", "_calls")
        |> sanitize_usage_map("server_side_tool_usage", "_calls")
        |> sanitize_usage_map("server_tool_use", "_requests")
      end)
    else
      body
    end
  end

  defp sanitize_provider_success(body, _provider), do: body

  defp sanitize_usage_map(usage, field, suffix) do
    Map.update(usage, field, nil, fn
      details when is_map(details) ->
        allowed = Enum.map(@openai_tool_usage_bases, &(&1 <> suffix))

        Enum.reduce(details, %{}, fn {key, count}, acc ->
          if key in allowed and is_number(count) and count > 0 and
               count <= @max_tool_usage_count,
             do: Map.put(acc, key, count),
             else: acc
        end)

      _details ->
        %{}
    end)
  end

  defp redact(value, secrets) when is_binary(value) do
    Enum.reduce(secrets, value, &String.replace(&2, &1, "[REDACTED]"))
  end

  defp redact(value, secrets) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, redact(nested, secrets)} end)
  end

  defp redact(value, secrets) when is_list(value), do: Enum.map(value, &redact(&1, secrets))
  defp redact(value, _secrets), do: value

  defp scrub_error_response(%Req.Response{body: body} = response) do
    %{
      response
      | body: safe_error_body(body),
        headers: Req.Fields.new([]),
        trailers: Req.Fields.new([])
    }
  end

  defp decode_success(_request, %Req.Response{} = response, "openai_codex") do
    with true <- event_stream_response?(response),
         :ok <- validate_codex_sse(response.body) do
      {:ok, response}
    else
      _invalid -> {:error, :invalid_provider_response}
    end
  end

  defp decode_success(request, %Req.Response{} = response, provider) do
    case response.body do
      body when is_map(body) ->
        validate_json_shape(response, body, provider, request.url.path)

      body when is_binary(body) ->
        with true <- json_response?(response),
             {:ok, decoded} when is_map(decoded) <- Jason.decode(body),
             true <- valid_json_shape?(provider, request.url.path, decoded) do
          {:ok, %{response | body: decoded}}
        else
          _invalid -> {:error, :invalid_provider_response}
        end

      _invalid ->
        {:error, :invalid_provider_response}
    end
  end

  defp validate_json_shape(response, body, provider, path) do
    if valid_json_shape?(provider, path, body),
      do: {:ok, response},
      else: {:error, :invalid_provider_response}
  end

  defp valid_json_shape?("openai", path, body) when path in ["/v1/models", "/models"],
    do: is_list(body["data"])

  defp valid_json_shape?("openai", path, body) do
    if String.ends_with?(path, "/responses"),
      do: is_list(body["output"]),
      else: is_list(body["choices"])
  end

  defp valid_json_shape?("anthropic", path, body) when path in ["/v1/models", "/models"],
    do: is_list(body["data"])

  defp valid_json_shape?("anthropic", _path, body),
    do: body["type"] == "message" and is_list(body["content"]) and body["content"] != []

  defp valid_json_shape?("openrouter", path, body) when path in ["/api/v1/key", "/key"],
    do: is_map(body["data"])

  defp valid_json_shape?("openrouter", _path, body), do: is_list(body["choices"])
  defp valid_json_shape?(_provider, _path, _body), do: false

  defp content_type?(response, expected) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(&String.contains?(&1, expected))
  end

  defp json_response?(response), do: content_type?(response, "application/json")
  defp event_stream_response?(response), do: content_type?(response, "text/event-stream")

  defp validate_codex_sse(body) when is_binary(body) do
    events = ReqLLM.Streaming.SSE.parse_sse_binary(body)

    if events != [] and Enum.all?(events, &safe_codex_event?/1),
      do: :ok,
      else: {:error, :invalid_provider_response}
  rescue
    _exception -> {:error, :invalid_provider_response}
  end

  defp validate_codex_sse(_body), do: {:error, :invalid_provider_response}

  defp safe_codex_event?(%{data: "[DONE]"}), do: true

  defp safe_codex_event?(%{data: data} = event) when is_map(data) do
    type = event[:event] || data["event"] || data["type"]
    type not in ["error", "response.failed"]
  end

  defp safe_codex_event?(_event), do: false

  defp safe_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> safe_error_body(decoded)
      {:error, _reason} -> %{}
    end
  end

  defp safe_error_body(%{"error" => error}) when is_map(error) do
    safe_error = safe_error(error)

    %{"error" => safe_error}
  end

  defp safe_error_body(_body), do: %{}

  defp maybe_put_safe(map, key, value, allowed) do
    if value in allowed, do: Map.put(map, key, value), else: map
  end

  defp safe_error(%{
         "type" => "invalid_request_error",
         "message" => message
       })
       when is_binary(message) do
    cond do
      message == @anthropic_workspace_required_message ->
        %{"code" => "workspace_selection_required"}

      Enum.any?(@anthropic_spend_limit_prefixes, &String.starts_with?(message, &1)) ->
        %{"code" => "spend_limit_reached"}

      true ->
        %{"type" => "invalid_request_error"}
    end
  end

  defp safe_error(%{"details" => %{"error_code" => "enforced_spend_limit_reached"}}),
    do: %{"code" => "enforced_spend_limit_reached"}

  defp safe_error(error) do
    %{}
    |> maybe_put_safe("code", error["code"], @safe_error_codes)
    |> maybe_put_safe("type", error["type"], @safe_error_types)
  end

  defp safe_transport_error(%Req.TransportError{reason: reason})
       when reason in [:closed, :timeout, :econnrefused, :nxdomain],
       do: Kodo.LLM.SafeTransportError.exception(reason: :network)

  defp safe_transport_error(%Mint.TransportError{}),
    do: Kodo.LLM.SafeTransportError.exception(reason: :network)

  defp safe_transport_error(%Kodo.LLM.SafeTransportError{reason: reason})
       when reason in [:network, :tls, :request, :invalid_origin],
       do: Kodo.LLM.SafeTransportError.exception(reason: reason)

  defp safe_transport_error(_exception),
    do: Kodo.LLM.SafeTransportError.exception(reason: :request)

  defp safe_mint_error(%Mint.TransportError{reason: reason})
       when reason in [:closed, :timeout, :econnrefused, :nxdomain],
       do: Kodo.LLM.SafeTransportError.exception(reason: :network)

  defp safe_mint_error(%Mint.TransportError{reason: {:tls_alert, _detail}}),
    do: Kodo.LLM.SafeTransportError.exception(reason: :tls)

  defp safe_mint_error(%Mint.TransportError{}),
    do: Kodo.LLM.SafeTransportError.exception(reason: :network)

  defp safe_mint_error(_reason),
    do: Kodo.LLM.SafeTransportError.exception(reason: :request)

  defp validate_origin(request, provider) do
    with {:ok, expected} <- Map.fetch(@provider_origins, provider),
         true <- origin(request.url) == expected or test_origin?(request.url) do
      :ok
    else
      _invalid -> {:error, :invalid_origin}
    end
  end

  defp origin(%URI{scheme: scheme, host: host, port: port, userinfo: nil})
       when is_binary(scheme) and is_binary(host),
       do: {scheme, String.downcase(host), port || default_port(scheme)}

  defp origin(_url), do: nil

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_scheme), do: nil

  if @allow_test_origins do
    defp test_origin?(url),
      do: origin(url) in Application.get_env(:kodo, :safe_req_test_origins, [])
  else
    defp test_origin?(_url), do: false
  end
end
