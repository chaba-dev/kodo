defmodule Kodo.IntegrationsTest do
  use Kodo.DataCase, async: true

  import ExUnit.CaptureLog

  alias Kodo.AccountsFixtures
  alias Kodo.Integrations
  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.DeviceAuthorizationAttempt
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
      assert integration.active
      assert integration.display_name == "OpenAI API"
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

    test "supports multiple provider accounts with one explicitly active", %{scope: scope} do
      assert {:ok, first} = connect(scope, "first-secret", display_name: "Personal")
      assert {:ok, second} = connect(scope, "second-secret", display_name: "Work")

      assert first.active
      refute second.active
      assert second.display_name == "Work"
      assert {:ok, active} = Integrations.get_active_integration_by_provider(scope, "openai")
      assert active.id == first.id

      assert {:ok, activated} =
               Integrations.activate(scope, second.id, second.credential_generation)

      assert activated.active
      assert {:ok, active} = Integrations.get_active_integration_by_provider(scope, "openai")
      assert active.id == second.id
      refute Repo.reload!(first).active

      assert {:ok, disconnected} =
               Integrations.disconnect(scope, second.id, second.credential_generation)

      refute disconnected.active

      assert {:error, :integration_not_found} =
               Integrations.get_active_integration_by_provider(scope, "openai")

      assert {:ok, reactivated} =
               Integrations.activate(scope, first.id, first.credential_generation)

      assert reactivated.active
    end

    test "re-activating the active account preserves it without duplicate audit events", %{
      scope: scope
    } do
      assert {:ok, first} = connect(scope, "first-secret", display_name: "Personal")
      assert {:ok, second} = connect(scope, "second-secret", display_name: "Work")

      assert {:ok, activated} =
               Integrations.activate(scope, second.id, second.credential_generation)

      assert {:ok, unchanged} =
               Integrations.activate(scope, activated.id, activated.credential_generation)

      assert unchanged.active
      assert Repo.reload!(unchanged).active
      refute Repo.reload!(first).active

      assert Enum.count(
               Integrations.list_audit_events(scope),
               &(&1.event_type == "integration_activated")
             ) == 1
    end

    test "adding an account after disconnecting the active one does not choose a fallback", %{
      scope: scope
    } do
      assert {:ok, active} = connect(scope, "first-secret")
      assert {:ok, inactive} = connect(scope, "second-secret")

      assert {:ok, _disconnected} =
               Integrations.disconnect(scope, active.id, active.credential_generation)

      assert {:ok, added} = connect(scope, "third-secret")

      refute Repo.reload!(inactive).active
      refute added.active

      assert {:error, :integration_not_found} =
               Integrations.get_active_integration_by_provider(scope, "openai")
    end

    test "activation is owned, connected, and generation fenced", %{scope: scope} do
      other_scope = AccountsFixtures.user_scope_fixture()
      assert {:ok, integration} = connect(scope)

      assert {:error, :integration_not_found} =
               Integrations.activate(
                 other_scope,
                 integration.id,
                 integration.credential_generation
               )

      assert {:error, :stale_credential_generation} =
               Integrations.activate(scope, integration.id, integration.credential_generation + 1)

      assert {:ok, disconnected} =
               Integrations.disconnect(scope, integration.id, integration.credential_generation)

      assert {:error, :integration_not_connected} =
               Integrations.activate(scope, disconnected.id, disconnected.credential_generation)
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
      refute reauthorization.active
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

    test "activates only the first OAuth account after authorization", %{scope: scope} do
      first = oauth_integration(scope)

      assert {:ok, first} =
               Integrations.oauth_succeeded(scope, first.id, 0, %{
                 "access_token" => "first-access",
                 "refresh_token" => "first-refresh",
                 "account_id" => "first-account"
               })

      assert first.active

      second = oauth_integration(scope)

      assert {:ok, second} =
               Integrations.oauth_succeeded(scope, second.id, 0, %{
                 "access_token" => "second-access",
                 "refresh_token" => "second-refresh",
                 "account_id" => "second-account"
               })

      refute second.active
      assert Repo.reload!(first).active
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
      refute connected.active
      assert connected.credential_generation == disconnected.credential_generation + 1
    end

    test "reauthorizing after invalid grant does not reactivate the account", %{scope: scope} do
      integration = oauth_integration(scope)

      assert {:ok, connected} =
               Integrations.oauth_succeeded(scope, integration.id, 0, %{
                 "access_token" => "access",
                 "refresh_token" => "refresh"
               })

      assert connected.active

      assert {:ok, reauthorization} =
               Integrations.refresh_invalid_grant(
                 scope,
                 connected.id,
                 connected.credential_generation
               )

      assert {:ok, reauthorized} =
               Integrations.oauth_succeeded(
                 scope,
                 reauthorization.id,
                 reauthorization.credential_generation,
                 %{"access_token" => "new-access", "refresh_token" => "new-refresh"}
               )

      refute reauthorized.active
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

  describe "device authorization attempt lifecycle" do
    setup do
      %{scope: AccountsFixtures.user_scope_fixture()}
    end

    test "starts and reads an encrypted, generation-fenced attempt", %{scope: scope} do
      integration = oauth_integration(scope)
      payload = %{"device_auth_id" => "device-secret", "user_code" => "ABCD-EFGH"}

      assert {:ok, attempt} =
               Integrations.begin_device_authorization(
                 scope,
                 integration.id,
                 integration.credential_generation,
                 payload,
                 0
               )

      assert attempt.state == "active"
      assert attempt.attempt_generation == 1
      assert attempt.expected_integration_generation == 1
      assert DateTime.diff(attempt.provider_deadline, attempt.inserted_at, :second) in 899..900

      assert DateTime.diff(attempt.provider_deadline, attempt.next_poll_at, :millisecond) ==
               900_000

      refute attempt.encrypted_payload =~ "device-secret"

      assert {:ok, {read_attempt, ^payload}} =
               Integrations.get_active_device_authorization(scope, integration.id)

      assert read_attempt.id == attempt.id
      assert Repo.reload!(integration).credential_generation == 1

      assert Enum.map(Integrations.list_audit_events(scope), & &1.event_type) == [
               "device_authorization_started"
             ]
    end

    test "atomically supersedes the prior attempt and clears its sensitive payload", %{
      scope: scope
    } do
      integration = oauth_integration(scope)
      payload = %{"device_auth_id" => "first", "user_code" => "FIRST"}

      assert {:ok, first} =
               Integrations.begin_device_authorization(scope, integration.id, 0, payload, 1_000)

      assert {:ok, second} =
               Integrations.begin_device_authorization(
                 scope,
                 integration.id,
                 1,
                 %{"device_auth_id" => "second", "user_code" => "SECOND"},
                 2_000
               )

      first = Repo.reload!(first)
      assert first.state == "cancelled"
      assert first.terminal_error_code == "superseded"
      assert is_nil(first.encrypted_payload)
      assert second.attempt_generation == 2
      assert second.expected_integration_generation == 2
    end

    test "reauthorization cancellation and expiry preserve a working integration", %{
      scope: scope
    } do
      integration = oauth_integration(scope)

      assert {:ok, connected} =
               Integrations.oauth_succeeded(scope, integration.id, 0, %{
                 "access_token" => "access",
                 "refresh_token" => "refresh"
               })

      assert {:ok, valid} =
               Integrations.validation_succeeded(
                 scope,
                 connected.id,
                 connected.credential_generation
               )

      assert valid.active

      assert {:ok, first} =
               Integrations.begin_device_authorization(
                 scope,
                 valid.id,
                 valid.credential_generation,
                 %{"device_auth_id" => "first", "user_code" => "FIRST"},
                 1_000
               )

      after_start = Repo.reload!(valid)
      assert after_start.connection_status == "connected"
      assert after_start.validation_status == "valid"
      assert after_start.active

      assert {:ok, _cancelled} =
               Integrations.cancel_device_authorization(
                 scope,
                 first.id,
                 first.attempt_generation
               )

      assert %{connection_status: "connected", validation_status: "valid", active: true} =
               Repo.reload!(valid)

      after_cancel = Repo.reload!(valid)

      assert {:ok, second} =
               Integrations.begin_device_authorization(
                 scope,
                 after_cancel.id,
                 after_cancel.credential_generation,
                 %{"device_auth_id" => "second", "user_code" => "SECOND"},
                 1_000
               )

      Repo.update!(
        change(second, provider_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
      )

      assert {:error, :device_authorization_not_found} =
               Integrations.get_active_device_authorization(scope, valid.id)

      assert %{connection_status: "connected", validation_status: "valid", active: true} =
               Repo.reload!(valid)
    end

    test "attempt operations suppress identifiers and ciphertext from query observability", %{
      scope: scope
    } do
      integration = oauth_integration(scope)
      handler_id = "device-attempt-observability-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:kodo, :repo, :query],
          fn _event, _measurements, metadata, pid -> send(pid, {:repo_query, metadata}) end,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, attempt} =
                   Integrations.begin_device_authorization(
                     scope,
                     integration.id,
                     0,
                     %{"device_auth_id" => "telemetry-device", "user_code" => "TELEMETRY"},
                     1_000
                   )

          assert {:ok, {_attempt, _payload}} =
                   Integrations.get_active_device_authorization(scope, integration.id)

          assert {:ok, _cancelled} =
                   Integrations.cancel_device_authorization(
                     scope,
                     attempt.id,
                     attempt.attempt_generation
                   )

          metadata = collect_query_metadata([])
          assert metadata != []
          observed = inspect(metadata, limit: :infinity, printable_limit: :infinity)

          refute observed =~ attempt.id
          refute observed =~ inspect(attempt.encrypted_payload)
          refute observed =~ Base.encode64(attempt.encrypted_payload)
        end)

      refute log =~ "telemetry-device"
      refute log =~ "TELEMETRY"
    end

    test "rejects stale, cross-user, malformed, and unsupported starts", %{scope: scope} do
      integration = oauth_integration(scope)
      other_scope = AccountsFixtures.user_scope_fixture()

      assert {:error, :integration_not_found} =
               Integrations.begin_device_authorization(
                 other_scope,
                 integration.id,
                 0,
                 %{"device_auth_id" => "device", "user_code" => "CODE"},
                 1_000
               )

      assert {:error, :stale_credential_generation} =
               Integrations.begin_device_authorization(
                 scope,
                 integration.id,
                 1,
                 %{"device_auth_id" => "device", "user_code" => "CODE"},
                 1_000
               )

      for payload <- [
            %{"device_auth_id" => "", "user_code" => "CODE"},
            %{"device_auth_id" => "device"},
            %{"device_auth_id" => "device", "user_code" => "CODE", "extra" => "value"}
          ] do
        assert {:error, :device_authorization_invalid} =
                 Integrations.begin_device_authorization(
                   scope,
                   integration.id,
                   0,
                   payload,
                   1_000
                 )
      end

      assert {:ok, api_key_integration} = connect(scope)

      assert {:error, :authentication_type_mismatch} =
               Integrations.begin_device_authorization(
                 scope,
                 api_key_integration.id,
                 api_key_integration.credential_generation,
                 %{"device_auth_id" => "device", "user_code" => "CODE"},
                 1_000
               )
    end

    test "cancellation is owned and generation fenced and removes the one-time code", %{
      scope: scope
    } do
      integration = oauth_integration(scope)
      other_scope = AccountsFixtures.user_scope_fixture()

      assert {:ok, attempt} =
               Integrations.begin_device_authorization(
                 scope,
                 integration.id,
                 0,
                 %{"device_auth_id" => "device", "user_code" => "CODE"},
                 1_000
               )

      assert {:error, :stale_device_authorization} =
               Integrations.cancel_device_authorization(
                 other_scope,
                 attempt.id,
                 attempt.attempt_generation
               )

      assert {:error, :stale_device_authorization} =
               Integrations.cancel_device_authorization(
                 scope,
                 attempt.id,
                 attempt.attempt_generation + 1
               )

      assert {:ok, cancelled} =
               Integrations.cancel_device_authorization(
                 scope,
                 attempt.id,
                 attempt.attempt_generation
               )

      assert cancelled.state == "cancelled"
      assert is_nil(cancelled.encrypted_payload)

      assert {:error, :device_authorization_not_found} =
               Integrations.get_active_device_authorization(scope, integration.id)
    end

    test "reads expire overdue attempts and disconnect cancels active attempts", %{scope: scope} do
      integration = oauth_integration(scope)

      assert {:ok, expired} =
               Integrations.begin_device_authorization(
                 scope,
                 integration.id,
                 0,
                 %{"device_auth_id" => "device", "user_code" => "CODE"},
                 1_000
               )

      Repo.update!(
        change(expired, provider_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
      )

      assert {:error, :device_authorization_not_found} =
               Integrations.get_active_device_authorization(scope, integration.id)

      expired = Repo.reload!(expired)
      assert expired.state == "expired"
      assert is_nil(expired.encrypted_payload)

      integration = Repo.reload!(integration)

      assert {:ok, active} =
               Integrations.begin_device_authorization(
                 scope,
                 integration.id,
                 integration.credential_generation,
                 %{"device_auth_id" => "new", "user_code" => "NEW"},
                 1_000
               )

      integration = Repo.reload!(integration)

      assert {:ok, _disconnected} =
               Integrations.disconnect(scope, integration.id, integration.credential_generation)

      assert %{state: "cancelled", encrypted_payload: nil} = Repo.reload!(active)
    end

    test "deletes old terminal attempts in bounded batches", %{scope: scope} do
      integration = oauth_integration(scope)

      attempts =
        for generation <- 0..2 do
          integration = Repo.reload!(integration)

          assert {:ok, attempt} =
                   Integrations.begin_device_authorization(
                     scope,
                     integration.id,
                     generation,
                     %{"device_auth_id" => "device", "user_code" => "CODE"},
                     1_000
                   )

          assert {:ok, cancelled} =
                   Integrations.cancel_device_authorization(
                     scope,
                     attempt.id,
                     attempt.attempt_generation
                   )

          Repo.update!(change(cancelled, updated_at: DateTime.add(DateTime.utc_now(), -2, :day)))
        end

      assert {:ok, 2} = Integrations.cleanup_device_authorizations(2)
      assert Repo.aggregate(DeviceAuthorizationAttempt, :count) == 1
      assert {:ok, 1} = Integrations.cleanup_device_authorizations(2)
      assert Enum.all?(attempts, &(Repo.get(DeviceAuthorizationAttempt, &1.id) == nil))
    end
  end

  defp connect(scope, secret \\ "provider-secret", opts \\ []) do
    Integrations.connect(scope, "openai", "api_key", %{"api_key" => secret}, opts)
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

  defp collect_query_metadata(acc) do
    receive do
      {:repo_query, metadata} -> collect_query_metadata([metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
