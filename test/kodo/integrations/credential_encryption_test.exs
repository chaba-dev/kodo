defmodule Kodo.Integrations.CredentialEncryptionTest do
  use ExUnit.Case, async: false

  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.Integration

  @config_key Kodo.Integrations.CredentialEncryption

  setup do
    original = Application.fetch_env!(:kodo, @config_key)
    on_exit(fn -> Application.put_env(:kodo, @config_key, original) end)
    :ok
  end

  test "round trips credentials without exposing provider identifiers outside the payload" do
    integration = integration()

    payload = %{
      "api_key" => "provider-secret",
      "account_id" => "provider-account-secret"
    }

    assert {:ok, encrypted} = CredentialEncryption.encrypt(integration, payload)

    refute encrypted.encrypted_credentials =~ "provider-secret"
    refute encrypted.encrypted_credentials =~ "provider-account-secret"
    assert encrypted.encryption_key_version == "test-v1"
    assert encrypted.credential_format_version == 1

    assert {:ok, ^payload} =
             integration
             |> Map.merge(encrypted)
             |> CredentialEncryption.decrypt()
  end

  test "uses a unique nonce for every write" do
    integration = integration()
    payload = %{"api_key" => "same-secret"}

    assert {:ok, first} = CredentialEncryption.encrypt(integration, payload)
    assert {:ok, second} = CredentialEncryption.encrypt(integration, payload)

    refute first.encrypted_credentials == second.encrypted_credentials
  end

  test "rejects ciphertext moved across bound identities" do
    integration = integration()
    assert {:ok, encrypted} = CredentialEncryption.encrypt(integration, %{"api_key" => "secret"})
    encrypted_integration = Map.merge(integration, encrypted)

    swaps = [
      %{encrypted_integration | id: Ecto.UUID.generate()},
      %{encrypted_integration | user_id: integration.user_id + 1},
      %{encrypted_integration | provider: "anthropic"},
      %{encrypted_integration | authentication_type: "oauth"}
    ]

    for swapped <- swaps do
      assert {:error, :credential_payload_corrupt} = CredentialEncryption.decrypt(swapped)
    end
  end

  test "rejects ciphertext tampering and the wrong key" do
    integration = integration()
    assert {:ok, encrypted} = CredentialEncryption.encrypt(integration, %{"api_key" => "secret"})
    encrypted_integration = Map.merge(integration, encrypted)

    <<first, rest::binary>> = encrypted.encrypted_credentials

    tampered = %{
      encrypted_integration
      | encrypted_credentials: <<Bitwise.bxor(first, 1), rest::binary>>
    }

    assert {:error, :credential_payload_corrupt} = CredentialEncryption.decrypt(tampered)

    put_config("test-v1", %{"test-v1" => :binary.copy(<<9>>, 32)})

    assert {:error, :credential_payload_corrupt} =
             CredentialEncryption.decrypt(encrypted_integration)
  end

  test "fails closed for unknown payload and key versions" do
    integration = integration()
    assert {:ok, encrypted} = CredentialEncryption.encrypt(integration, %{"api_key" => "secret"})
    encrypted_integration = Map.merge(integration, encrypted)

    assert {:error, :credential_payload_version_unsupported} =
             CredentialEncryption.decrypt(%{encrypted_integration | credential_format_version: 2})

    assert {:error, :credential_encryption_key_unavailable} =
             CredentialEncryption.decrypt(%{
               encrypted_integration
               | encryption_key_version: "missing"
             })
  end

  test "rejects missing, malformed, and incomplete encryption configuration" do
    for config <- [
          [],
          [current_key_version: "test-v1", keys: %{}],
          [current_key_version: "missing", keys: %{"test-v1" => :binary.copy(<<1>>, 32)}],
          [current_key_version: "test-v1", keys: %{"test-v1" => "too-short"}]
        ] do
      Application.put_env(:kodo, @config_key, config)

      assert {:error, :credential_encryption_config_invalid} =
               CredentialEncryption.validate_config()

      assert {:error, :credential_encryption_unavailable} =
               CredentialEncryption.encrypt(integration(), %{"api_key" => "secret"})
    end
  end

  test "rejects encryption without complete associated identity" do
    assert {:error, :credential_encryption_unavailable} =
             CredentialEncryption.encrypt(%Integration{}, %{"api_key" => "secret"})
  end

  defp integration do
    %Integration{
      id: Ecto.UUID.generate(),
      user_id: 123,
      provider: "openai",
      authentication_type: "api_key"
    }
  end

  defp put_config(current, keys) do
    Application.put_env(:kodo, @config_key, current_key_version: current, keys: keys)
  end
end
