defmodule Kodo.IntegrationsTest do
  use Kodo.DataCase, async: true

  alias Kodo.AccountsFixtures
  alias Kodo.Integrations
  alias Kodo.Integrations.CredentialEncryption

  describe "scoped credential lifecycle" do
    setup do
      %{scope: AccountsFixtures.user_scope_fixture()}
    end

    test "connects, lists, and retrieves only owned integration metadata", %{scope: scope} do
      other_scope = AccountsFixtures.user_scope_fixture()

      assert {:ok, integration} =
               Integrations.connect(scope, "openai", "api_key", %{"api_key" => "owner-secret"})

      assert integration.user_id == scope.user.id
      assert integration.connection_status == "connected"
      assert integration.validation_status == "unverified"
      assert integration.credential_generation == 1
      assert {:ok, %{"api_key" => "owner-secret"}} = CredentialEncryption.decrypt(integration)

      assert [listed] = Integrations.list_integrations(scope)
      assert listed.id == integration.id
      assert Integrations.list_integrations(other_scope) == []

      assert {:error, :integration_not_found} =
               Integrations.get_integration(other_scope, integration.id)

      assert {:error, :integration_not_found} =
               Integrations.get_integration_by_provider(other_scope, "openai")
    end

    test "enforces one integration per user and provider", %{scope: scope} do
      assert {:ok, _integration} = connect(scope)
      assert {:error, changeset} = connect(scope)
      assert "has already been taken" in errors_on(changeset).user_id
    end

    test "replaces credentials with a new nonce and advances the generation", %{scope: scope} do
      assert {:ok, integration} = connect(scope)
      original_ciphertext = integration.encrypted_credentials

      assert {:ok, replaced} =
               Integrations.replace_credentials(
                 scope,
                 integration.id,
                 integration.credential_generation,
                 %{"api_key" => "replacement-secret"}
               )

      assert replaced.credential_generation == 2
      refute replaced.encrypted_credentials == original_ciphertext

      assert {:ok, %{"api_key" => "replacement-secret"}} =
               CredentialEncryption.decrypt(replaced)

      assert {:error, :stale_credential_generation} =
               Integrations.replace_credentials(
                 scope,
                 replaced.id,
                 1,
                 %{"api_key" => "stale-secret"}
               )
    end

    test "records fenced validation outcomes without changing credential generation", %{
      scope: scope
    } do
      assert {:ok, integration} = connect(scope)
      generation = integration.credential_generation

      assert {:ok, invalid} =
               Integrations.validation_invalid(scope, integration.id, generation)

      assert invalid.validation_status == "invalid"
      assert invalid.validation_error_code == "invalid_credentials"
      assert invalid.credential_generation == generation

      assert {:ok, valid} = Integrations.validation_succeeded(scope, integration.id, generation)
      assert valid.validation_status == "valid"
      assert is_nil(valid.validation_error_code)

      assert {:ok, unavailable} =
               Integrations.validation_unavailable(scope, integration.id, generation, "timeout")

      assert unavailable.validation_status == "unavailable"
      assert unavailable.validation_error_code == "timeout"

      assert {:error, :unsafe_validation_error} =
               Integrations.validation_unavailable(
                 scope,
                 integration.id,
                 generation,
                 "provider body with secret"
               )
    end

    test "disconnects without a provider call and rejects delayed updates", %{scope: scope} do
      assert {:ok, integration} = connect(scope)
      generation = integration.credential_generation

      assert {:ok, disconnected} =
               Integrations.disconnect(scope, integration.id, generation)

      assert disconnected.connection_status == "disconnected"
      assert disconnected.validation_status == "unverified"
      assert disconnected.credential_generation == generation + 1
      assert is_nil(disconnected.encrypted_credentials)
      assert is_nil(disconnected.encryption_key_version)
      assert is_nil(disconnected.credential_format_version)

      assert {:error, :stale_credential_generation} =
               Integrations.validation_succeeded(scope, integration.id, generation)
    end

    test "retains provisional OAuth credentials until a fenced refresh succeeds", %{scope: scope} do
      assert {:ok, integration} =
               Integrations.connect(scope, "openai_codex", "oauth", %{
                 "access_token" => "old-access",
                 "refresh_token" => "old-refresh",
                 "account_id" => "account"
               })

      generation = integration.credential_generation

      assert {:ok, reauthorization} =
               Integrations.refresh_invalid_grant(scope, integration.id, generation)

      assert reauthorization.connection_status == "reauthorization_required"
      assert reauthorization.validation_status == "unverified"
      assert reauthorization.encrypted_credentials == integration.encrypted_credentials
      assert reauthorization.credential_generation == generation

      assert {:ok, refreshed} =
               Integrations.refresh_succeeded(
                 scope,
                 integration.id,
                 generation,
                 %{
                   "access_token" => "new-access",
                   "refresh_token" => "new-refresh",
                   "account_id" => "account"
                 },
                 refreshed_at: DateTime.utc_now()
               )

      assert refreshed.connection_status == "connected"
      assert refreshed.credential_generation == generation + 1

      assert {:ok, %{"access_token" => "new-access"}} =
               CredentialEncryption.decrypt(refreshed)
               |> then(fn {:ok, payload} -> {:ok, Map.take(payload, ["access_token"])} end)
    end

    test "rejects OAuth-only transitions for API-key integrations", %{scope: scope} do
      assert {:ok, integration} = connect(scope)

      assert {:error, :authentication_type_mismatch} =
               Integrations.refresh_invalid_grant(
                 scope,
                 integration.id,
                 integration.credential_generation
               )

      assert {:error, :authentication_type_mismatch} =
               Integrations.oauth_succeeded(
                 scope,
                 integration.id,
                 integration.credential_generation,
                 %{"access_token" => "wrong-route"}
               )
    end

    test "installs a generation-fenced OAuth authorization after disconnection", %{scope: scope} do
      assert {:ok, integration} =
               Integrations.connect(scope, "openai_codex", "oauth", %{
                 "access_token" => "old-access",
                 "refresh_token" => "old-refresh"
               })

      assert {:ok, disconnected} =
               Integrations.disconnect(
                 scope,
                 integration.id,
                 integration.credential_generation
               )

      assert {:ok, connected} =
               Integrations.oauth_succeeded(
                 scope,
                 integration.id,
                 disconnected.credential_generation,
                 %{"access_token" => "authorized", "refresh_token" => "refresh"}
               )

      assert connected.connection_status == "connected"
      assert connected.validation_status == "unverified"
      assert connected.credential_generation == disconnected.credential_generation + 1
    end

    test "rejects forged and cross-user generation-fenced transitions", %{scope: scope} do
      other_scope = AccountsFixtures.user_scope_fixture()
      assert {:ok, integration} = connect(scope)

      assert {:error, :stale_credential_generation} =
               Integrations.disconnect(
                 other_scope,
                 integration.id,
                 integration.credential_generation
               )

      assert {:error, :stale_credential_generation} =
               Integrations.disconnect(scope, Ecto.UUID.generate(), 0)

      assert {:ok, current} = Integrations.get_integration(scope, integration.id)
      assert current.connection_status == "connected"
    end
  end

  defp connect(scope) do
    Integrations.connect(scope, "openai", "api_key", %{"api_key" => "provider-secret"})
  end
end
