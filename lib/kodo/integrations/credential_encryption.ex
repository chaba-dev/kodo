defmodule Kodo.Integrations.CredentialEncryption do
  @moduledoc "Encrypts provider credentials with identity-bound authenticated encryption."

  alias Kodo.Integrations.Integration

  @format_version 1
  @nonce_bytes 12
  @tag_bytes 16
  @key_bytes 32

  @doc "Encrypts a credential payload using the configured current key."
  def encrypt(%Integration{} = integration, payload) when is_map(payload) do
    with {:ok, ring} <- key_ring(),
         {:ok, associated_data} <- associated_data(integration, @format_version),
         {:ok, plaintext} <- Jason.encode(payload) do
      nonce = :crypto.strong_rand_bytes(@nonce_bytes)
      key = Map.fetch!(ring.keys, ring.current_key_version)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          nonce,
          plaintext,
          associated_data,
          @tag_bytes,
          true
        )

      {:ok,
       %{
         encrypted_credentials: nonce <> tag <> ciphertext,
         encryption_key_version: ring.current_key_version,
         credential_format_version: @format_version
       }}
    else
      _error -> {:error, :credential_encryption_unavailable}
    end
  end

  @doc "Decrypts and authenticates an integration's credential payload."
  def decrypt(%Integration{credential_format_version: version}) when version != @format_version,
    do: {:error, :credential_payload_version_unsupported}

  def decrypt(%Integration{} = integration) do
    with {:ok, ring} <- key_ring(),
         {:ok, key} <- fetch_decryption_key(ring, integration.encryption_key_version),
         {:ok, associated_data} <- associated_data(integration, @format_version),
         {:ok, nonce, tag, ciphertext} <- unpack(integration.encrypted_credentials),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             associated_data,
             tag,
             false
           ),
         {:ok, payload} when is_map(payload) <- Jason.decode(plaintext) do
      {:ok, payload}
    else
      {:error, :credential_encryption_key_unavailable} = error -> error
      _error -> {:error, :credential_payload_corrupt}
    end
  end

  @doc "Validates the configured current and previous encryption keys."
  def validate_config do
    case key_ring() do
      {:ok, _ring} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp key_ring do
    config = Application.get_env(:kodo, __MODULE__, [])
    current_key_version = config[:current_key_version]
    keys = config[:keys]

    if is_binary(current_key_version) and current_key_version != "" and is_map(keys) and
         map_size(keys) > 0 and Map.has_key?(keys, current_key_version) and
         Enum.all?(keys, fn {version, key} ->
           is_binary(version) and version != "" and is_binary(key) and
             byte_size(key) == @key_bytes
         end) do
      {:ok, %{current_key_version: current_key_version, keys: keys}}
    else
      {:error, :credential_encryption_config_invalid}
    end
  end

  defp associated_data(integration, format_version) do
    values = [
      integration.id,
      integration.user_id,
      integration.provider,
      integration.authentication_type,
      format_version
    ]

    if Enum.all?(values, &(not is_nil(&1))) do
      Jason.encode(values)
    else
      {:error, :credential_identity_incomplete}
    end
  end

  defp fetch_decryption_key(ring, version) do
    case Map.fetch(ring.keys, version) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :credential_encryption_key_unavailable}
    end
  end

  defp unpack(
         <<nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>
       )
       when byte_size(ciphertext) > 0,
       do: {:ok, nonce, tag, ciphertext}

  defp unpack(_payload), do: {:error, :credential_payload_malformed}
end
