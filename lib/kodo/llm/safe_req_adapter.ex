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
  @max_token_count 1_000_000_000
  @usage_fields ~w(
    input_tokens output_tokens reasoning_tokens cached_tokens
  )a
  @optional_usage_fields ~w(
    cache_creation_tokens cache_read_input_tokens cache_creation_input_tokens
  )a
  @tool_usage_keys %{
    "function" => :function,
    "web_search" => :web_search,
    "web_search_preview" => :web_search_preview,
    "web_fetch" => :web_fetch,
    "file_search" => :file_search,
    "mcp" => :mcp,
    "x_search" => :x_search,
    "code_interpreter" => :code_interpreter
  }
  @tool_usage_units %{"call" => :call, "request" => :request, "source" => :source}
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
    case decode_success(request, response, provider, secrets) do
      {:ok, response} ->
        if credential_in_key?(response.body, secrets) do
          {scrub_request(request), safe_transport_error(:invalid_provider_response)}
        else
          request = request |> scrub_request() |> protect_response_decoding(secrets)
          {request, sanitize_success(response, provider, secrets)}
        end

      {:error, reason} ->
        {scrub_request(request), safe_transport_error(reason)}
    end
  end

  defp sanitize_result({request, %Req.Response{} = response}, _secrets, provider),
    do: {scrub_request(request), scrub_error_response(response, provider)}

  defp sanitize_result({request, exception}, _secrets, _provider) when is_exception(exception),
    do: {scrub_request(request), safe_transport_error(exception)}

  # ReqLLM owns provider decoders after the adapter returns. Wrap those steps so
  # a future decoder exception cannot reintroduce an untrusted body into its
  # error telemetry; this compatibility fence can go when ReqLLM bounds errors.
  defp protect_response_decoding(request, secrets) do
    steps =
      Enum.map(request.response_steps, fn
        {name, step} when is_function(step, 1) ->
          {name,
           fn request_and_response ->
             run_safe_response_step(name, step, request_and_response, secrets)
           end}

        step ->
          step
      end)

    %{request | response_steps: steps}
  end

  defp run_safe_response_step(
         name,
         step,
         {%Req.Request{} = request, %Req.Response{}} = input,
         secrets
       ) do
    case step.(input) do
      {%Req.Request{} = request, %Req.Response{body: %ReqLLM.Response{} = body} = response}
      when name == :llm_decode_response ->
        case sanitize_decoded_response(body, secrets) do
          {:ok, body} -> {request, %{response | body: body}}
          :error -> {scrub_request(request), safe_transport_error(:invalid_provider_response)}
        end

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

  defp credential_in_key?(value, secrets) when is_map(value) do
    Enum.any?(value, fn {key, nested} ->
      (is_binary(key) and Enum.any?(secrets, &String.contains?(key, &1))) or
        credential_in_key?(nested, secrets)
    end)
  end

  defp credential_in_key?(value, secrets) when is_list(value),
    do: Enum.any?(value, &credential_in_key?(&1, secrets))

  defp credential_in_key?(_value, _secrets), do: false

  defp sanitize_decoded_response(response, secrets) do
    with false <- credential_in_response?(response, secrets),
         false <- credential_in_composed_output?(response, secrets),
         {:ok, response} <- canonicalize_assistant_metadata(response),
         {:ok, response} <- canonicalize_usage(response) do
      {:ok, response}
    else
      _unsafe -> :error
    end
  end

  defp credential_in_composed_output?(response, secrets) do
    tool_arguments = Enum.map(ReqLLM.Response.tool_calls(response), &ReqLLM.ToolCall.args_map/1)

    [ReqLLM.Response.text(response), ReqLLM.Response.thinking(response), tool_arguments]
    |> Enum.any?(&credential_present?(&1, secrets))
  end

  defp credential_in_response?(%ReqLLM.Response{} = response, secrets) do
    [
      response.id,
      response.model,
      response.message,
      response.object,
      response.provider_meta,
      response.error
    ]
    |> Enum.any?(&credential_present?(&1, secrets))
  end

  defp credential_present?(value, secrets) when is_binary(value) do
    Enum.any?(secrets, &String.contains?(value, &1)) or
      case Jason.decode(value) do
        {:ok, decoded} -> credential_present?(decoded, secrets)
        {:error, _reason} -> false
      end
  end

  defp credential_present?(value, secrets) when is_struct(value),
    do: value |> Map.from_struct() |> credential_present?(secrets)

  defp credential_present?(value, secrets) when is_map(value) do
    Enum.any?(value, fn {key, nested} ->
      credential_present?(key, secrets) or credential_present?(nested, secrets)
    end)
  end

  defp credential_present?(value, secrets) when is_list(value),
    do: Enum.any?(value, &credential_present?(&1, secrets))

  defp credential_present?(value, secrets) when is_tuple(value),
    do: value |> Tuple.to_list() |> credential_present?(secrets)

  defp credential_present?(_value, _secrets), do: false

  # ReqLLM intentionally retains unknown provider fields for lossless proxying.
  # Kodo persists assistant state, so keep only documented continuation fields
  # until ReqLLM exposes a bounded representation for that trust boundary.
  defp canonicalize_assistant_metadata(
         %ReqLLM.Response{message: %ReqLLM.Message{} = message} = response
       ) do
    with {:ok, message} <- canonicalize_message(message) do
      context = canonicalize_response_context(response.context, message)
      {:ok, %{response | message: message, context: context}}
    end
  end

  defp canonicalize_assistant_metadata(_response), do: :error

  defp canonicalize_message(%ReqLLM.Message{reasoning_details: nil} = message) do
    with {:ok, content} <- canonicalize_content(message.content),
         {:ok, metadata} <- canonicalize_message_metadata(message.metadata) do
      {:ok, %{message | content: content, metadata: metadata}}
    end
  end

  defp canonicalize_message(%ReqLLM.Message{reasoning_details: details} = message)
       when is_list(details) do
    with {:ok, content} <- canonicalize_content(message.content),
         {:ok, details} <- canonicalize_reasoning_details(details),
         {:ok, metadata} <- canonicalize_message_metadata(message.metadata) do
      {:ok, %{message | content: content, reasoning_details: details, metadata: metadata}}
    end
  end

  defp canonicalize_message(_message), do: :error

  defp canonicalize_reasoning_details(details) do
    Enum.reduce_while(details, {:ok, []}, fn detail, {:ok, acc} ->
      case canonicalize_reasoning_detail(detail) do
        {:ok, detail} -> {:cont, {:ok, [detail | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp canonicalize_reasoning_detail(%ReqLLM.Message.ReasoningDetails{} = detail) do
    if optional_binary?(detail.text) and optional_binary?(detail.signature) and
         is_boolean(detail.encrypted?) and
         detail.provider in [:anthropic, :google, :openai, :openai_codex, :openrouter] and
         optional_binary?(detail.format) and is_integer(detail.index) and detail.index >= 0 and
         (is_nil(detail.provider_data) or is_map(detail.provider_data)) do
      {:ok, %{detail | provider_data: canonical_reasoning_provider_data(detail)}}
    else
      :error
    end
  end

  defp canonicalize_reasoning_detail(_detail), do: :error

  defp canonicalize_content(content) when is_list(content) do
    Enum.reduce_while(content, {:ok, []}, fn part, {:ok, acc} ->
      case canonicalize_content_part(part) do
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp canonicalize_content(_content), do: :error

  defp canonicalize_content_part(%ReqLLM.Message.ContentPart{} = part) do
    if part.type in [:text, :image_url, :video_url, :image, :file, :thinking] and
         optional_binary?(part.text) and optional_binary?(part.url) and
         optional_binary?(part.data) and optional_binary?(part.file_id) and
         optional_binary?(part.media_type) and optional_binary?(part.filename) and
         is_map(part.metadata) do
      {:ok, %{part | metadata: %{}}}
    else
      :error
    end
  end

  defp canonicalize_content_part(%{type: :object, object: object}) when is_map(object) do
    {:ok, ReqLLM.Message.ContentPart.text(Jason.encode!(object))}
  end

  defp canonicalize_content_part(_part), do: :error

  defp optional_binary?(value), do: is_nil(value) or is_binary(value)

  defp canonicalize_message_metadata(metadata) when is_map(metadata) do
    with {:ok, response_id} <- optional_metadata_string(metadata, :response_id),
         {:ok, phase} <- optional_assistant_phase(metadata),
         {:ok, phase_items} <- optional_phase_items(metadata) do
      {:ok,
       %{}
       |> maybe_put_metadata(:response_id, response_id)
       |> maybe_put_metadata(:phase, phase)
       |> maybe_put_metadata(:phase_items, phase_items)}
    end
  end

  defp canonicalize_message_metadata(_metadata), do: :error

  defp optional_metadata_string(metadata, key) do
    case fetch_metadata(metadata, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _invalid} -> :error
    end
  end

  defp optional_assistant_phase(metadata) do
    case fetch_metadata(metadata, :phase) do
      :error -> {:ok, nil}
      {:ok, phase} when phase in ["commentary", "final_answer"] -> {:ok, phase}
      {:ok, _invalid} -> :error
    end
  end

  defp optional_phase_items(metadata) do
    case fetch_metadata(metadata, :phase_items) do
      :error -> {:ok, nil}
      {:ok, items} when is_list(items) -> canonicalize_phase_items(items)
      {:ok, _invalid} -> :error
    end
  end

  defp canonicalize_phase_items(items) do
    if Enum.all?(items, &valid_phase_item?/1), do: {:ok, items}, else: :error
  end

  defp valid_phase_item?(%{"phase" => phase, "content" => content})
       when phase in ["commentary", "final_answer"] and is_list(content) do
    Enum.all?(content, fn
      %{"type" => "output_text", "text" => text} when is_binary(text) -> true
      _invalid -> false
    end)
  end

  defp valid_phase_item?(_item), do: false

  defp fetch_metadata(metadata, key) do
    case Map.fetch(metadata, key) do
      :error -> Map.fetch(metadata, Atom.to_string(key))
      result -> result
    end
  end

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp canonical_reasoning_provider_data(%{provider: :openrouter, provider_data: data})
       when is_map(data) do
    %{}
    |> maybe_put_reasoning_field(
      "type",
      data,
      ~w(reasoning.text reasoning.summary reasoning.encrypted)
    )
    |> maybe_put_reasoning_string("id", data)
    |> maybe_put_reasoning_string("data", data)
    |> maybe_put_reasoning_string("summary", data)
  end

  defp canonical_reasoning_provider_data(%{provider: provider, provider_data: data})
       when provider in [:openai, :openai_codex] and is_map(data) do
    %{}
    |> maybe_put_reasoning_field("type", data, ["reasoning"])
    |> maybe_put_reasoning_string("id", data)
  end

  defp canonical_reasoning_provider_data(%{provider: :google, provider_data: data})
       when is_map(data) do
    if map_value(data, "thought") == true, do: %{"thought" => true}, else: %{}
  end

  defp canonical_reasoning_provider_data(_detail), do: %{}

  defp maybe_put_reasoning_field(result, key, data, allowed) do
    case map_value(data, key) do
      value -> if value in allowed, do: Map.put(result, key, value), else: result
    end
  end

  defp maybe_put_reasoning_string(result, key, data) do
    case map_value(data, key) do
      value when is_binary(value) -> Map.put(result, key, value)
      _other -> result
    end
  end

  defp map_value(map, "type"), do: Map.get(map, "type", Map.get(map, :type))
  defp map_value(map, "id"), do: Map.get(map, "id", Map.get(map, :id))
  defp map_value(map, "data"), do: Map.get(map, "data", Map.get(map, :data))
  defp map_value(map, "summary"), do: Map.get(map, "summary", Map.get(map, :summary))
  defp map_value(map, "thought"), do: Map.get(map, "thought", Map.get(map, :thought))

  defp canonicalize_response_context(
         %ReqLLM.Context{messages: [_first | _rest]} = context,
         message
       ) do
    %{context | messages: List.replace_at(context.messages, -1, message)}
  end

  defp canonicalize_response_context(context, _message), do: context

  defp canonicalize_usage(%ReqLLM.Response{usage: nil} = response), do: {:ok, response}

  defp canonicalize_usage(%ReqLLM.Response{usage: usage} = response) when is_map(usage) do
    with {:ok, counters} <- canonical_usage_counters(usage),
         {:ok, tool_usage} <- canonical_tool_usage(usage[:tool_usage] || usage["tool_usage"]) do
      {:ok, %{response | usage: Map.put(counters, :tool_usage, tool_usage)}}
    end
  end

  defp canonicalize_usage(_response), do: :error

  defp canonical_usage_counters(usage) do
    with {:ok, counters} <-
           Enum.reduce_while(@usage_fields, {:ok, %{}}, fn field, {:ok, acc} ->
             value = Map.get(usage, field, Map.get(usage, Atom.to_string(field), 0))

             if valid_usage_count?(value),
               do: {:cont, {:ok, Map.put(acc, field, value)}},
               else: {:halt, :error}
           end),
         total <-
           Map.get(
             usage,
             :total_tokens,
             Map.get(usage, "total_tokens", counters.input_tokens + counters.output_tokens)
           ),
         true <- valid_usage_count?(total),
         {:ok, counters} <- canonical_optional_usage_counters(usage, counters) do
      {:ok, Map.put(counters, :total_tokens, total)}
    else
      _invalid -> :error
    end
  end

  defp valid_usage_count?(value),
    do: is_integer(value) and value >= 0 and value <= @max_token_count

  defp canonical_optional_usage_counters(usage, counters) do
    Enum.reduce_while(@optional_usage_fields, {:ok, counters}, fn field, {:ok, acc} ->
      string_field = Atom.to_string(field)

      cond do
        Map.has_key?(usage, field) and valid_usage_count?(usage[field]) ->
          {:cont, {:ok, Map.put(acc, field, usage[field])}}

        Map.has_key?(usage, string_field) and valid_usage_count?(usage[string_field]) ->
          {:cont, {:ok, Map.put(acc, field, usage[string_field])}}

        Map.has_key?(usage, field) or Map.has_key?(usage, string_field) ->
          {:halt, :error}

        true ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp canonical_tool_usage(nil), do: {:ok, %{}}

  defp canonical_tool_usage(usage) when is_map(usage) do
    Enum.reduce_while(usage, {:ok, %{}}, fn {key, entry}, {:ok, acc} ->
      with {:ok, key} <- canonical_tool_key(key),
           {:ok, entry} <- canonical_tool_entry(entry) do
        {:cont, {:ok, Map.put(acc, key, entry)}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  defp canonical_tool_usage(_usage), do: :error

  defp canonical_tool_key(key) when is_atom(key), do: canonical_tool_key(Atom.to_string(key))

  defp canonical_tool_key(key) when is_binary(key) do
    Map.fetch(@tool_usage_keys, key)
  end

  defp canonical_tool_key(_key), do: :error

  defp canonical_tool_entry(entry) when is_map(entry) do
    count = entry[:count] || entry["count"]
    unit = entry[:unit] || entry["unit"] || :call

    with true <- is_integer(count) and count > 0 and count <= @max_tool_usage_count,
         {:ok, unit} <- canonical_tool_unit(unit) do
      {:ok, %{count: count, unit: unit}}
    else
      _invalid -> :error
    end
  end

  defp canonical_tool_entry(_entry), do: :error

  defp canonical_tool_unit(unit) when is_atom(unit), do: canonical_tool_unit(Atom.to_string(unit))
  defp canonical_tool_unit(unit) when is_binary(unit), do: Map.fetch(@tool_usage_units, unit)
  defp canonical_tool_unit(_unit), do: :error

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

  defp scrub_error_response(%Req.Response{body: body} = response, provider) do
    %{
      response
      | body: safe_error_body(body, provider),
        headers: Req.Fields.new([]),
        trailers: Req.Fields.new([])
    }
  end

  defp decode_success(_request, %Req.Response{} = response, "openai_codex", secrets) do
    with true <- event_stream_response?(response),
         {:ok, events} <- decode_codex_sse(response.body),
         false <- credential_present?(events, secrets),
         :ok <- validate_codex_tool_streams(events) do
      {:ok, response}
    else
      _invalid -> {:error, :invalid_provider_response}
    end
  rescue
    _exception -> {:error, :invalid_provider_response}
  catch
    _kind, _reason -> {:error, :invalid_provider_response}
  end

  defp decode_success(request, %Req.Response{} = response, provider, _secrets) do
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

  defp decode_codex_sse(body) when is_binary(body) do
    events = ReqLLM.Streaming.SSE.parse_sse_binary(body)

    if events != [] and Enum.all?(events, &safe_codex_event?/1),
      do: {:ok, events},
      else: {:error, :invalid_provider_response}
  rescue
    _exception -> {:error, :invalid_provider_response}
  end

  defp decode_codex_sse(_body), do: {:error, :invalid_provider_response}

  defp validate_codex_tool_streams(events) do
    state =
      Enum.reduce(
        events,
        %{calls: MapSet.new(), fragments: %{}, valid?: true},
        &track_codex_tool_event/2
      )

    if state.valid? and
         Enum.all?(state.calls, &valid_codex_tool_arguments?(&1, state.fragments)),
       do: :ok,
       else: {:error, :invalid_provider_response}
  end

  defp track_codex_tool_event(%{data: data} = event, state) when is_map(data) do
    type = event[:event] || data["event"] || data["type"]
    index = data["output_index"] || data["index"] || 0

    case type do
      "response.output_item.added" ->
        track_codex_tool_start(state, index, data["item"])

      "response.function_call.name.delta" ->
        if is_binary(data["delta"]) and data["delta"] != "",
          do: add_codex_tool_call(state, index),
          else: invalidate_codex_tool_stream(state)

      "response.function_call.delta" ->
        track_codex_function_delta(state, index, data["delta"])

      "response.function_call_arguments.delta" ->
        append_codex_tool_arguments(state, index, data["delta"])

      "response.function_call_arguments.done" ->
        if Map.has_key?(state.fragments, index),
          do: state,
          else: append_codex_tool_arguments(state, index, data["arguments"] || data["delta"])

      "response.output_item.done" ->
        track_codex_tool_done(state, index, data["item"])

      _other ->
        state
    end
  end

  defp track_codex_tool_event(_event, state), do: state

  defp track_codex_function_delta(state, index, delta) when is_map(delta) do
    state =
      if is_binary(delta["name"]) and delta["name"] != "",
        do: add_codex_tool_call(state, index),
        else: state

    case delta["arguments"] do
      nil -> state
      arguments -> append_codex_tool_arguments(state, index, arguments)
    end
  end

  defp track_codex_function_delta(state, _index, _delta),
    do: invalidate_codex_tool_stream(state)

  defp track_codex_tool_start(state, index, %{"type" => "function_call", "name" => name})
       when is_binary(name) and name != "",
       do: add_codex_tool_call(state, index)

  defp track_codex_tool_start(state, _index, _item), do: state

  defp track_codex_tool_done(state, index, %{"type" => "function_call"} = item) do
    state =
      if is_binary(item["name"]) and item["name"] != "",
        do: add_codex_tool_call(state, index),
        else: state

    if Map.has_key?(state.fragments, index),
      do: state,
      else: append_codex_tool_arguments(state, index, item["arguments"])
  end

  defp track_codex_tool_done(state, _index, _item), do: state

  defp add_codex_tool_call(state, index),
    do: %{state | calls: MapSet.put(state.calls, index)}

  defp append_codex_tool_arguments(state, index, fragment)
       when is_binary(fragment) and fragment != "" do
    %{state | fragments: Map.update(state.fragments, index, [fragment], &[&1, fragment])}
  end

  defp append_codex_tool_arguments(state, _index, _fragment), do: state

  defp invalidate_codex_tool_stream(state), do: %{state | valid?: false}

  defp valid_codex_tool_arguments?(index, fragments) do
    with parts when is_list(parts) <- Map.get(fragments, index),
         {:ok, decoded} <- parts |> IO.iodata_to_binary() |> Jason.decode(),
         true <- is_map(decoded) do
      true
    else
      _invalid -> false
    end
  end

  defp safe_codex_event?(%{data: "[DONE]"}), do: true

  defp safe_codex_event?(%{data: data} = event) when is_map(data) do
    type = event[:event] || data["event"] || data["type"]
    type not in ["error", "response.failed"]
  end

  defp safe_codex_event?(_event), do: false

  defp safe_error_body(body, provider) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> safe_error_body(decoded, provider)
      {:error, _reason} -> %{}
    end
  end

  defp safe_error_body(%{"error" => error}, provider) when is_map(error) do
    safe_error = safe_error(error, provider)

    %{"error" => safe_error}
  end

  defp safe_error_body(_body, _provider), do: %{}

  defp maybe_put_safe(map, key, value, allowed) do
    if value in allowed, do: Map.put(map, key, value), else: map
  end

  defp safe_error(
         %{
           "type" => "invalid_request_error",
           "message" => message
         },
         "anthropic"
       )
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

  defp safe_error(
         %{"details" => %{"error_code" => "enforced_spend_limit_reached"}},
         "anthropic"
       ),
       do: %{"code" => "enforced_spend_limit_reached"}

  defp safe_error(error, _provider) do
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
