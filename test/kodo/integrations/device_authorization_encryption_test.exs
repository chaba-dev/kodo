defmodule Kodo.Integrations.DeviceAuthorizationEncryptionTest do
  use ExUnit.Case, async: false

  alias Kodo.Integrations.DeviceAuthorizationAttempt
  alias Kodo.Integrations.DeviceAuthorizationEncryption

  @config_key Kodo.Integrations.CredentialEncryption

  setup do
    original = Application.fetch_env!(:kodo, @config_key)
    on_exit(fn -> Application.put_env(:kodo, @config_key, original) end)
    :ok
  end

  test "round trips sensitive device state with a unique nonce" do
    attempt = attempt()

    payload = %{
      "device_auth_id" => "device-secret",
      "user_code" => "ABCD-EFGH"
    }

    assert {:ok, first} = DeviceAuthorizationEncryption.encrypt(attempt, payload)
    assert {:ok, second} = DeviceAuthorizationEncryption.encrypt(attempt, payload)

    refute first.encrypted_payload == second.encrypted_payload
    refute first.encrypted_payload =~ "device-secret"
    refute first.encrypted_payload =~ "ABCD-EFGH"
    assert first.encryption_key_version == "test-v1"
    assert first.payload_format_version == 1

    assert {:ok, ^payload} =
             attempt
             |> Map.merge(first)
             |> DeviceAuthorizationEncryption.decrypt()
  end

  test "rejects ciphertext moved across attempt identity boundaries" do
    attempt = attempt()

    assert {:ok, encrypted} =
             DeviceAuthorizationEncryption.encrypt(attempt, %{"user_code" => "secret"})

    encrypted_attempt = Map.merge(attempt, encrypted)

    swaps = [
      %{encrypted_attempt | id: Ecto.UUID.generate()},
      %{encrypted_attempt | integration_id: Ecto.UUID.generate()},
      %{encrypted_attempt | user_id: attempt.user_id + 1},
      %{encrypted_attempt | provider: "openai"},
      %{encrypted_attempt | attempt_generation: attempt.attempt_generation + 1}
    ]

    for swapped <- swaps do
      assert {:error, :authorization_payload_corrupt} =
               DeviceAuthorizationEncryption.decrypt(swapped)
    end
  end

  test "rejects tampering, malformed payloads, unknown formats, and unavailable keys" do
    attempt = attempt()

    assert {:ok, encrypted} =
             DeviceAuthorizationEncryption.encrypt(attempt, %{"user_code" => "secret"})

    encrypted_attempt = Map.merge(attempt, encrypted)
    <<first, rest::binary>> = encrypted.encrypted_payload

    assert {:error, :authorization_payload_corrupt} =
             DeviceAuthorizationEncryption.decrypt(%{
               encrypted_attempt
               | encrypted_payload: <<Bitwise.bxor(first, 1), rest::binary>>
             })

    assert {:error, :authorization_payload_corrupt} =
             DeviceAuthorizationEncryption.decrypt(%{
               encrypted_attempt
               | encrypted_payload: <<1, 2, 3>>
             })

    assert {:error, :authorization_payload_version_unsupported} =
             DeviceAuthorizationEncryption.decrypt(%{
               encrypted_attempt
               | payload_format_version: 2
             })

    assert {:error, :authorization_encryption_key_unavailable} =
             DeviceAuthorizationEncryption.decrypt(%{
               encrypted_attempt
               | encryption_key_version: "missing"
             })
  end

  test "fails closed without complete identity or valid payload and redacts secrets" do
    sentinel = "plaintext-device-secret"

    assert {:error, :authorization_encryption_unavailable} =
             DeviceAuthorizationEncryption.encrypt(%DeviceAuthorizationAttempt{}, %{
               "user_code" => sentinel
             })

    assert result = {:error, :authorization_payload_invalid}
    assert ^result = DeviceAuthorizationEncryption.encrypt(attempt(), sentinel)
    refute inspect(result) =~ sentinel

    refute inspect(%DeviceAuthorizationAttempt{encrypted_payload: sentinel}) =~ sentinel
  end

  defp attempt do
    %DeviceAuthorizationAttempt{
      id: Ecto.UUID.generate(),
      integration_id: Ecto.UUID.generate(),
      user_id: 123,
      provider: "openai_codex",
      attempt_generation: 1
    }
  end
end
