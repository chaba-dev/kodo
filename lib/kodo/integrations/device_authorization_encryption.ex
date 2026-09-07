defmodule Kodo.Integrations.DeviceAuthorizationEncryption do
  @moduledoc "Encrypts device-authorization payloads with immutable attempt identity binding."

  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.DeviceAuthorizationAttempt

  @doc "Encrypts sensitive provider state for a pre-identified attempt."
  def encrypt(%DeviceAuthorizationAttempt{} = attempt, payload) do
    # Device attempts and connected credentials share key rotation and AEAD
    # mechanics, but this wrapper keeps their identities and bounded errors
    # separate so one payload type can never be decrypted as the other.
    case CredentialEncryption.encrypt_bound(identity(attempt), payload) do
      {:ok, encrypted} ->
        {:ok,
         %{
           encrypted_payload: encrypted.ciphertext,
           encryption_key_version: encrypted.key_version,
           payload_format_version: encrypted.format_version
         }}

      {:error, reason} ->
        {:error, translate_error(reason)}
    end
  end

  def encrypt(_attempt, _payload), do: {:error, :authorization_payload_invalid}

  @doc "Decrypts sensitive provider state only for its original attempt identity."
  def decrypt(%DeviceAuthorizationAttempt{} = attempt) do
    case CredentialEncryption.decrypt_bound(
           identity(attempt),
           attempt.encrypted_payload,
           attempt.encryption_key_version,
           attempt.payload_format_version
         ) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  defp identity(attempt) do
    [
      "device_authorization_attempt",
      attempt.id,
      attempt.integration_id,
      attempt.user_id,
      attempt.provider,
      attempt.attempt_generation
    ]
  end

  defp translate_error(:credential_payload_invalid), do: :authorization_payload_invalid

  defp translate_error(:credential_encryption_unavailable),
    do: :authorization_encryption_unavailable

  defp translate_error(:credential_payload_version_unsupported),
    do: :authorization_payload_version_unsupported

  defp translate_error(:credential_encryption_key_unavailable),
    do: :authorization_encryption_key_unavailable

  defp translate_error(:credential_payload_corrupt), do: :authorization_payload_corrupt
end
