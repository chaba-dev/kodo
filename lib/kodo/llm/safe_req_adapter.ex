defmodule Kodo.LLM.SafeReqAdapter do
  @moduledoc """
  Scrubs provider HTTP results before ReqLLM can observe them.

  ReqLLM's terminal-error telemetry retains its input error, including response
  and request bodies. Kodo cannot sanitize that telemetry after the call returns,
  so this adapter wraps Req's Finch boundary and removes operation-local secrets
  and untrusted error details before ReqLLM's response, logging, and telemetry
  steps execute. Only documented identifiers needed for safe classification are
  retained from non-successful provider responses.
  """

  @credential_option_keys ~w(api_key access_token auth_mode oauth_file auth_file provider_options chatgpt_account_id)a
  @credential_headers ~w(authorization x-api-key chatgpt-account-id)
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
  @safe_error_types ~w(authentication_error billing_error permission_error rate_limit_error)

  def run(%Req.Request{} = request) do
    secrets = credential_values(request)

    case Req.Finch.run(request) do
      {request, %Req.Response{status: status} = response} when status in 200..299 ->
        {scrub_request(request), redact_success(response, secrets)}

      {request, %Req.Response{} = response} ->
        {scrub_request(request), scrub_error_response(response)}

      {request, exception} when is_exception(exception) ->
        {scrub_request(request), safe_transport_error(exception)}
    end
  end

  defp credential_values(request) do
    @credential_headers
    |> Enum.flat_map(&Req.Request.get_header(request, &1))
    |> Enum.map(&String.replace_prefix(&1, "Bearer ", ""))
    |> Enum.reject(&(&1 == ""))
  end

  defp scrub_request(request) do
    request = Enum.reduce(@credential_headers, request, &Req.Request.delete_header(&2, &1))
    %{request | body: nil, options: Map.drop(request.options, @credential_option_keys)}
  end

  defp redact_success(%Req.Response{body: body} = response, secrets) do
    %{response | body: redact(body, secrets)}
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

  defp safe_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> safe_error_body(decoded)
      {:error, _reason} -> %{}
    end
  end

  defp safe_error_body(%{"error" => error}) when is_map(error) do
    safe_error =
      %{}
      |> maybe_put_safe("code", error["code"], @safe_error_codes)
      |> maybe_put_safe("type", error["type"], @safe_error_types)

    %{"error" => safe_error}
  end

  defp safe_error_body(_body), do: %{}

  defp maybe_put_safe(map, key, value, allowed) do
    if value in allowed, do: Map.put(map, key, value), else: map
  end

  defp safe_transport_error(%Req.TransportError{reason: reason})
       when reason in [:closed, :timeout, :econnrefused, :nxdomain],
       do: Kodo.LLM.SafeTransportError.exception(reason: :network)

  defp safe_transport_error(_exception),
    do: Kodo.LLM.SafeTransportError.exception(reason: :request)
end
