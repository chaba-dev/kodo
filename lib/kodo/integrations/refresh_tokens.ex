defmodule Kodo.Integrations.RefreshTokens do
  @moduledoc false

  @account_claim "https://api.openai.com/auth"
  @max_token_bytes 8_192

  def normalize(response, current, now \\ DateTime.utc_now())

  def normalize(response, current, %DateTime{} = now)
      when is_map(response) and is_map(current) do
    with {:ok, access_token} <- token(response, "access_token"),
         {:ok, expires_at} <- access_expiry(access_token, now),
         {:ok, refresh_token} <- optional_token(response, current, "refresh_token"),
         {:ok, id_token} <- optional_token(response, current, "id_token"),
         {:ok, current_account_id} <- token(current, "account_id"),
         {:ok, account_id} <- account_id(response, id_token, current_account_id),
         true <- account_id == current_account_id do
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
      false -> {:error, :refresh_account_identity_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def normalize(_response, _current, _now), do: {:error, :oauth_refresh_response_invalid}

  defp account_id(response, id_token, current_account_id) do
    if Map.has_key?(response, "id_token") do
      with {:ok, claims} <- jwt_claims(id_token),
           %{"chatgpt_account_id" => account_id} <- claims[@account_claim],
           :ok <- valid_token(account_id) do
        {:ok, account_id}
      else
        _invalid -> {:error, :oauth_refresh_response_invalid}
      end
    else
      {:ok, current_account_id}
    end
  end

  defp access_expiry(access_token, now) do
    with {:ok, %{"exp" => unix}} when is_integer(unix) <- jwt_claims(access_token),
         {:ok, expires_at} <- DateTime.from_unix(unix),
         true <- DateTime.after?(expires_at, now) do
      {:ok, %{expires_at | microsecond: {0, 6}}}
    else
      _invalid -> {:error, :oauth_refresh_response_invalid}
    end
  end

  defp optional_token(response, current, field) do
    case Map.fetch(response, field) do
      {:ok, value} -> checked_token(value)
      :error -> token(current, field)
    end
  end

  defp token(payload, field), do: payload |> Map.get(field) |> checked_token()

  defp checked_token(value) do
    case valid_token(value) do
      :ok -> {:ok, value}
      :error -> {:error, :oauth_refresh_response_invalid}
    end
  end

  defp valid_token(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_token_bytes,
       do: :ok

  defp valid_token(_value), do: :error

  defp jwt_claims(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} when is_map(claims) <- Jason.decode(json) do
      {:ok, claims}
    else
      _invalid -> {:error, :oauth_refresh_response_invalid}
    end
  end
end
