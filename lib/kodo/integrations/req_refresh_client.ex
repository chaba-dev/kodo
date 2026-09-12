defmodule Kodo.Integrations.ReqRefreshClient do
  @moduledoc "Performs the pinned OpenAI Codex refresh-token contract."

  @behaviour Kodo.Integrations.RefreshClient

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @token_url "https://auth.openai.com/oauth/token"
  @timeout 10_000
  @max_response_bytes 8_192

  @impl true
  def refresh(refresh_token, req_options \\ [])

  def refresh(refresh_token, req_options)
      when is_binary(refresh_token) and byte_size(refresh_token) > 0 and
             byte_size(refresh_token) <= @max_response_bytes and is_list(req_options) do
    options =
      [
        url: @token_url,
        json: %{
          client_id: @client_id,
          grant_type: "refresh_token",
          refresh_token: refresh_token
        },
        adapter: Kodo.Integrations.CredentialReqAdapter,
        redirect: false,
        retry: false,
        decode_body: false,
        credential_request_timeout: @timeout
      ] ++
        Keyword.take(req_options, [
          :plug,
          :credential_request_transport,
          :credential_request_timeout
        ])

    request =
      Req.new()
      |> Req.Request.register_options([
        :credential_request_timeout,
        :credential_request_transport
      ])

    request |> Req.post(options) |> classify_response()
  end

  def refresh(_refresh_token, _req_options), do: {:error, :oauth_refresh_response_invalid}

  defp classify_response(result) do
    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        decode_success(body)

      {:ok, %Req.Response{status: status, body: body}} when status in [400, 401] ->
        if permanent_refresh_failure?(status, body),
          do: {:error, :invalid_grant},
          else: {:error, :provider_unavailable}

      {:ok, %Req.Response{status: status}} when status in 300..399 ->
        {:error, :redirect}

      {:ok, %Req.Response{}} ->
        {:error, :provider_unavailable}

      {:error, _reason} ->
        {:error, :provider_unavailable}
    end
  end

  defp decode_success(body) do
    with {:ok, decoded} when is_map(decoded) <- decode_json(body),
         access_token when is_binary(access_token) and byte_size(access_token) > 0 <-
           decoded["access_token"] do
      {:ok, decoded}
    else
      _invalid -> {:error, :oauth_refresh_response_invalid}
    end
  end

  defp permanent_refresh_failure?(401, _body), do: true

  defp permanent_refresh_failure?(400, body) do
    case decode_json(body) do
      {:ok, %{"error" => "invalid_grant"}} ->
        true

      {:ok, %{"code" => code}}
      when code in ~w(refresh_token_expired refresh_token_reused refresh_token_invalidated) ->
        true

      _other ->
        false
    end
  end

  defp decode_json(body) when is_binary(body), do: Jason.decode(body)
  defp decode_json(_body), do: {:error, :invalid_body}
end
