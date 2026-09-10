defmodule Kodo.Integrations.DeviceAuthorizationTokens do
  @moduledoc false

  @openai_auth_claim "https://api.openai.com/auth"

  def normalize(tokens, now \\ DateTime.utc_now())

  def normalize(
        %{
          "access_token" => access_token,
          "refresh_token" => refresh_token,
          "id_token" => id_token
        },
        now
      ) do
    with {:ok, access_claims} <- decode_claims(access_token),
         {:ok, identity_claims} <- decode_claims(id_token),
         {:ok, expires_at} <- expiration(access_claims, now),
         {:ok, account_id} <- account_id(identity_claims) do
      {:ok,
       %{
         credentials: %{
           "access_token" => access_token,
           "refresh_token" => refresh_token,
           "id_token" => id_token,
           "account_id" => account_id
         },
         expires_at: expires_at
       }}
    else
      _invalid -> {:error, :device_authorization_response_invalid}
    end
  end

  def normalize(_tokens, _now), do: {:error, :device_authorization_response_invalid}

  defp decode_claims(token) when is_binary(token) do
    case String.split(token, ".") do
      [_header, payload, _signature] ->
        with {:ok, decoded} <- Base.url_decode64(payload, padding: false),
             {:ok, claims} when is_map(claims) <- Jason.decode(decoded) do
          {:ok, claims}
        else
          _invalid -> :error
        end

      _invalid ->
        :error
    end
  end

  defp decode_claims(_token), do: :error

  defp expiration(%{"exp" => unix}, now) when is_integer(unix) do
    with {:ok, expires_at} <- DateTime.from_unix(unix),
         true <- DateTime.after?(expires_at, now) do
      {:ok, %{expires_at | microsecond: {0, 6}}}
    else
      _invalid -> :error
    end
  end

  defp expiration(_claims, _now), do: :error

  defp account_id(%{@openai_auth_claim => %{"chatgpt_account_id" => account_id}})
       when is_binary(account_id) and account_id != "",
       do: {:ok, account_id}

  defp account_id(_claims), do: :error
end
