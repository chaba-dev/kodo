defmodule Kodo.Integrations.CredentialKeyRingTest do
  use Kodo.DataCase, async: false

  alias Kodo.AccountsFixtures
  alias Kodo.Integrations.CredentialKeyRing
  alias Kodo.Integrations.DeviceAuthorizationAttempt
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

  test "validates keys referenced only by active device authorization attempts" do
    insert_attempt("test-old")
    assert :ok = CredentialKeyRing.validate_referenced_versions()

    insert_attempt("retired-v1")

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
      display_name: "OpenAI API",
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

  defp insert_attempt(key_version) do
    user = AccountsFixtures.user_fixture()

    integration =
      %Integration{user_id: user.id}
      |> Integration.create_changeset(%{
        provider: "openai_codex",
        authentication_type: "oauth"
      })
      |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %DeviceAuthorizationAttempt{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      integration_id: integration.id,
      provider: "openai_codex",
      attempt_generation: 1,
      expected_integration_generation: 0,
      encrypted_payload: "opaque",
      encryption_key_version: key_version,
      payload_format_version: 1,
      provider_deadline: DateTime.add(now, 900, :second),
      polling_interval_ms: 5_000,
      next_poll_at: now
    }
    |> change()
    |> DeviceAuthorizationAttempt.constraint_changeset()
    |> Repo.insert!()
  end
end
