defmodule Kodo.Integrations.ReqDeviceAuthorizationClient do
  @moduledoc "Performs the pinned OpenAI Codex device-authorization HTTP contract."

  @behaviour Kodo.Integrations.DeviceAuthorizationClient

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @create_url "https://auth.openai.com/api/accounts/deviceauth/usercode"
  @poll_url "https://auth.openai.com/api/accounts/deviceauth/token"
  @token_url "https://auth.openai.com/oauth/token"
  @verification_url "https://auth.openai.com/codex/device"
  @redirect_uri "https://auth.openai.com/deviceauth/callback"
  @timeout 10_000
  @max_field_bytes 8_192

  @impl true
  def create(req_options \\ []) do
    with {:ok, body} <- post(@create_url, [json: %{client_id: @client_id}], req_options),
         {:ok, device_auth_id} <- fetch_string(body, ["device_auth_id"]),
         {:ok, user_code} <- fetch_string(body, ["user_code", "usercode"]),
         {:ok, polling_interval_ms} <- parse_interval(body),
         :ok <- validate_verification_url(body) do
      {:ok,
       %{
         payload: %{"device_auth_id" => device_auth_id, "user_code" => user_code},
         polling_interval_ms: polling_interval_ms,
         verification_url: @verification_url
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def poll(payload, req_options \\ [])

  def poll(%{"device_auth_id" => device_auth_id, "user_code" => user_code}, req_options) do
    case request(
           @poll_url,
           [json: %{device_auth_id: device_auth_id, user_code: user_code}],
           req_options
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        with {:ok, authorization_code} <- fetch_string(body, ["authorization_code"]),
             {:ok, code_challenge} <- fetch_string(body, ["code_challenge"]),
             {:ok, code_verifier} <- fetch_string(body, ["code_verifier"]) do
          {:ok,
           %{
             "authorization_code" => authorization_code,
             "code_challenge" => code_challenge,
             "code_verifier" => code_verifier
           }}
        end

      {:ok, %Req.Response{status: status}} when status in [403, 404] ->
        :pending

      {:ok, %Req.Response{}} ->
        {:error, :device_authorization_rejected}

      {:error, _reason} = error ->
        error
    end
  end

  def poll(_payload, _req_options), do: {:error, :device_authorization_response_invalid}

  @impl true
  def exchange(payload, req_options \\ [])

  def exchange(
        %{"authorization_code" => authorization_code, "code_verifier" => code_verifier},
        req_options
      ) do
    with {:ok, body} <-
           post(
             @token_url,
             [
               form: %{
                 grant_type: "authorization_code",
                 code: authorization_code,
                 redirect_uri: @redirect_uri,
                 client_id: @client_id,
                 code_verifier: code_verifier
               }
             ],
             req_options
           ),
         {:ok, access_token} <- fetch_string(body, ["access_token"]),
         {:ok, refresh_token} <- fetch_string(body, ["refresh_token"]),
         {:ok, id_token} <- fetch_string(body, ["id_token"]) do
      {:ok,
       %{
         "access_token" => access_token,
         "refresh_token" => refresh_token,
         "id_token" => id_token
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  def exchange(_payload, _req_options), do: {:error, :device_authorization_response_invalid}

  def verification_url, do: @verification_url

  defp post(url, request_options, req_options) do
    case request(url, request_options, req_options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 404}} when url == @create_url ->
        {:error, :device_authorization_unsupported}

      {:ok, %Req.Response{}} ->
        {:error, :device_authorization_rejected}

      {:error, _reason} = error ->
        error
    end
  end

  defp request(url, request_options, req_options) when is_list(req_options) do
    # Only the transport can be replaced in tests. The credential-bearing
    # origin, redirect policy, client identity, and timeout stay immutable.
    req_options = Keyword.take(req_options, [:plug, :finch_request])

    options =
      [
        url: url,
        max_redirects: 0,
        retry: false,
        receive_timeout: @timeout,
        request_timeout: @timeout,
        finch: [
          pool_timeout: @timeout,
          conn_opts: [transport_opts: [timeout: @timeout]]
        ]
      ] ++ request_options ++ req_options

    case Req.post(options) do
      {:ok, response} -> {:ok, response}
      {:error, %Req.TooManyRedirectsError{}} -> {:error, :redirect}
      {:error, _error} -> {:error, :provider_unavailable}
    end
  rescue
    exception in RuntimeError ->
      if String.starts_with?(
           Exception.message(exception),
           "Finch was unable to provide a connection within the timeout"
         ) do
        {:error, :provider_unavailable}
      else
        reraise exception, __STACKTRACE__
      end
  end

  defp fetch_string(body, names) when is_map(body) do
    value = Enum.find_value(names, &Map.get(body, &1))

    if is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_field_bytes,
      do: {:ok, value},
      else: {:error, :device_authorization_response_invalid}
  end

  defp fetch_string(_body, _names), do: {:error, :device_authorization_response_invalid}

  defp parse_interval(%{"interval" => interval}) when is_binary(interval) do
    case Integer.parse(String.trim(interval)) do
      {seconds, ""} when seconds >= 0 and seconds <= 900 -> {:ok, seconds * 1_000}
      _other -> {:error, :device_authorization_response_invalid}
    end
  end

  defp parse_interval(_body), do: {:error, :device_authorization_response_invalid}

  defp validate_verification_url(body) do
    provider_url = body["verification_uri"] || body["verification_url"]

    if is_nil(provider_url) or provider_url == @verification_url,
      do: :ok,
      else: {:error, :device_authorization_response_invalid}
  end
end
