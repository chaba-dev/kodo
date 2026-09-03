defmodule Kodo.IntegrationsTest do
  use Kodo.DataCase, async: true

  alias Kodo.AccountsFixtures
  alias Kodo.Integrations
  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.Integration
  alias Kodo.Test.BlockingJSONValue

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
      assert {:error, :integration_already_exists} = connect(scope)
    end

    test "returns a bounded error when connection races account deletion", %{scope: scope} do
      Repo.delete!(scope.user)

      assert {:error, :integration_owner_not_found} = connect(scope)
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
      integration = oauth_integration(scope)

      assert {:ok, integration} =
               Integrations.oauth_succeeded(scope, integration.id, 0, %{
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

    test "rejects raw connect and replacement APIs for OAuth credentials", %{scope: scope} do
      assert {:error, :authentication_type_mismatch} =
               Integrations.connect(scope, "openai_codex", "oauth", %{
                 "access_token" => "raw-access",
                 "refresh_token" => "raw-refresh"
               })

      integration = oauth_integration(scope)

      assert {:ok, connected} =
               Integrations.oauth_succeeded(scope, integration.id, 0, %{
                 "access_token" => "authorized",
                 "refresh_token" => "refresh"
               })

      assert {:error, :authentication_type_mismatch} =
               Integrations.replace_credentials(
                 scope,
                 connected.id,
                 connected.credential_generation,
                 %{"access_token" => "raw-replacement"}
               )
    end

    test "installs a generation-fenced OAuth authorization after disconnection", %{scope: scope} do
      integration = oauth_integration(scope)

      assert {:ok, integration} =
               Integrations.oauth_succeeded(scope, integration.id, 0, %{
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

    test "admits exactly one of two replacements at the same generation", %{scope: scope} do
      assert {:ok, integration} = connect(scope)
      supervisor = start_supervised!(Task.Supervisor)
      owner = self()

      tasks =
        for suffix <- ["first", "second"] do
          ref = make_ref()

          task =
            async_operation(supervisor, fn ->
              Integrations.replace_credentials(
                scope,
                integration.id,
                integration.credential_generation,
                %{"api_key" => blocking_value(owner, ref, "replacement-#{suffix}")}
              )
            end)

          {task, ref}
        end

      Enum.each(tasks, fn {task, ref} -> assert_encoding_blocked(task, ref) end)
      Enum.each(tasks, fn {task, ref} -> send(task.pid, {:continue_json_encoding, ref}) end)

      results = Enum.map(tasks, fn {task, _ref} -> Task.await(task) end)

      assert Enum.count(results, &match?({:ok, _integration}, &1)) == 1

      assert Enum.count(results, &(&1 == {:error, :stale_credential_generation})) == 1

      assert {:ok, current} = Integrations.get_integration(scope, integration.id)
      assert current.credential_generation == integration.credential_generation + 1
    end

    test "delayed credential and validation results cannot undo disconnection", %{scope: scope} do
      assert {:ok, api_integration} = connect(scope)
      api_generation = api_integration.credential_generation
      supervisor = start_supervised!(Task.Supervisor)
      owner = self()
      replace_ref = make_ref()

      replace_task =
        async_operation(supervisor, fn ->
          Integrations.replace_credentials(
            scope,
            api_integration.id,
            api_generation,
            %{"api_key" => blocking_value(owner, replace_ref, "delayed")}
          )
        end)

      assert_encoding_blocked(replace_task, replace_ref)

      assert {:ok, _disconnected} =
               Integrations.disconnect(scope, api_integration.id, api_generation)

      send(replace_task.pid, {:continue_json_encoding, replace_ref})

      assert {:error, :stale_credential_generation} =
               Task.await(replace_task)

      assert {:error, :stale_credential_generation} =
               Integrations.validation_invalid(scope, api_integration.id, api_generation)

      oauth = oauth_integration(scope)
      oauth_ref = make_ref()

      oauth_task =
        async_operation(supervisor, fn ->
          Integrations.oauth_succeeded(scope, oauth.id, 0, %{
            "access_token" => blocking_value(owner, oauth_ref, "access"),
            "refresh_token" => "refresh"
          })
        end)

      assert_encoding_blocked(oauth_task, oauth_ref)
      assert {:ok, oauth_disconnected} = Integrations.disconnect(scope, oauth.id, 0)
      send(oauth_task.pid, {:continue_json_encoding, oauth_ref})

      assert {:error, :stale_credential_generation} = Task.await(oauth_task)
      assert oauth_disconnected.connection_status == "disconnected"

      refresh_scope = AccountsFixtures.user_scope_fixture()
      refresh = oauth_integration(refresh_scope)

      assert {:ok, refresh} =
               Integrations.oauth_succeeded(refresh_scope, refresh.id, 0, %{
                 "access_token" => "access",
                 "refresh_token" => "refresh"
               })

      refresh_ref = make_ref()

      refresh_task =
        async_operation(supervisor, fn ->
          Integrations.refresh_succeeded(
            refresh_scope,
            refresh.id,
            refresh.credential_generation,
            %{
              "access_token" => blocking_value(owner, refresh_ref, "new-access"),
              "refresh_token" => "new-refresh"
            }
          )
        end)

      assert_encoding_blocked(refresh_task, refresh_ref)

      assert {:ok, _disconnected} =
               Integrations.disconnect(
                 refresh_scope,
                 refresh.id,
                 refresh.credential_generation
               )

      send(refresh_task.pid, {:continue_json_encoding, refresh_ref})
      assert {:error, :stale_credential_generation} = Task.await(refresh_task)

      assert {:ok, current} = Integrations.get_integration(refresh_scope, refresh.id)
      assert current.connection_status == "disconnected"
      assert is_nil(current.encrypted_credentials)
    end

    test "deletion after credential lookup cannot recreate integration state", %{scope: scope} do
      assert {:ok, integration} = connect(scope)
      supervisor = start_supervised!(Task.Supervisor)
      owner = self()
      ref = make_ref()

      task =
        async_operation(supervisor, fn ->
          Integrations.replace_credentials(
            scope,
            integration.id,
            integration.credential_generation,
            %{"api_key" => blocking_value(owner, ref, "late-replacement")}
          )
        end)

      assert_encoding_blocked(task, ref)
      Repo.delete!(scope.user)
      send(task.pid, {:continue_json_encoding, ref})

      assert {:error, :stale_credential_generation} = Task.await(task)

      refute Repo.get(Integration, integration.id)
    end

    test "rejects validation and refresh transitions from illegal connection states", %{
      scope: scope
    } do
      oauth = oauth_integration(scope)

      assert {:error, :stale_credential_generation} =
               Integrations.validation_succeeded(scope, oauth.id, 0)

      assert {:error, :stale_credential_generation} =
               Integrations.refresh_succeeded(scope, oauth.id, 0, %{
                 "access_token" => "access",
                 "refresh_token" => "refresh"
               })

      assert {:ok, connected} =
               Integrations.oauth_succeeded(scope, oauth.id, 0, %{
                 "access_token" => "access",
                 "refresh_token" => "refresh"
               })

      assert {:ok, reauthorization} =
               Integrations.refresh_invalid_grant(
                 scope,
                 connected.id,
                 connected.credential_generation
               )

      assert {:error, :stale_credential_generation} =
               Integrations.validation_succeeded(
                 scope,
                 reauthorization.id,
                 reauthorization.credential_generation
               )

      assert {:error, :stale_credential_generation} =
               Integrations.refresh_invalid_grant(
                 scope,
                 reauthorization.id,
                 reauthorization.credential_generation
               )
    end
  end

  defp connect(scope) do
    Integrations.connect(scope, "openai", "api_key", %{"api_key" => "provider-secret"})
  end

  defp oauth_integration(scope) do
    %Integration{user_id: scope.user.id}
    |> Integration.create_changeset(%{
      provider: "openai_codex",
      authentication_type: "oauth"
    })
    |> Repo.insert!()
  end

  defp async_operation(supervisor, operation) do
    task = Task.Supervisor.async_nolink(supervisor, operation)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid)
    task
  end

  defp blocking_value(owner, ref, value) do
    %BlockingJSONValue{owner: owner, ref: ref, value: value}
  end

  defp assert_encoding_blocked(task, ref) do
    task_pid = task.pid
    assert_receive {:json_encoding_blocked, ^ref, ^task_pid}
  end
end
