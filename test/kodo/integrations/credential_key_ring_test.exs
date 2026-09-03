defmodule Kodo.Integrations.CredentialKeyRingTest do
  use Kodo.DataCase, async: false

  alias Kodo.AccountsFixtures
  alias Kodo.Integrations.CredentialKeyRing
  alias Kodo.Integrations.Integration

  @config_key Kodo.Integrations.CredentialEncryption

  setup do
    original = Application.fetch_env!(:kodo, @config_key)
    on_exit(fn -> Application.put_env(:kodo, @config_key, original) end)
    :ok
  end

  test "accepts every encryption key version referenced by persisted credentials" do
    insert_connected("test-v1")
    insert_connected("test-old")

    assert :ok = CredentialKeyRing.validate_referenced_versions()
    assert :ignore = CredentialKeyRing.start_link([])
  end

  test "fails readiness when a referenced encryption key is missing" do
    insert_connected("retired-v1")

    assert {:error, {:credential_encryption_keys_missing, ["retired-v1"]}} =
             CredentialKeyRing.validate_referenced_versions()
  end

  test "fails readiness when the configured key ring is malformed" do
    Application.put_env(:kodo, @config_key,
      current_key_version: "test-v1",
      keys: %{"test-v1" => "short"}
    )

    assert {:error, :credential_encryption_config_invalid} =
             CredentialKeyRing.validate_referenced_versions()

    assert {:error, :credential_encryption_config_invalid} = CredentialKeyRing.start_link([])
  end

  defp insert_connected(key_version) do
    user = AccountsFixtures.user_fixture()

    %Integration{
      user_id: user.id,
      provider: "openai",
      authentication_type: "api_key",
      connection_status: "connected",
      validation_status: "unverified",
      encrypted_credentials: "opaque",
      encryption_key_version: key_version,
      credential_format_version: 1
    }
    |> change()
    |> Integration.constraint_changeset()
    |> Repo.insert!()
  end
end
