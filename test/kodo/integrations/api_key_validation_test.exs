defmodule Kodo.Integrations.APIKeyValidationTest do
  use Kodo.DataCase, async: false

  import ExUnit.CaptureLog

  alias Kodo.AccountsFixtures
  alias Kodo.Integrations
  alias Kodo.Integrations.APIKeyValidation
  alias Kodo.Test.FakeAPIKeyValidationClient

  setup do
    scope = AccountsFixtures.user_scope_fixture()
    %{scope: scope}
  end

  for {prefix, status, error_code} <- [
        {"valid-", "valid", nil},
        {"invalid-", "invalid", "invalid_credentials"},
        {"revoked-", "invalid", "invalid_credentials"},
        {"permission-", "unavailable", "provider_unavailable"},
        {"timeout-", "unavailable", "timeout"},
        {"tls-", "unavailable", "tls_error"},
        {"redirect-", "unavailable", "provider_unavailable"},
        {"rate-limited-", "unavailable", "rate_limited"},
        {"provider-error-", "unavailable", "provider_unavailable"}
      ] do
    test "records #{status} for the bounded #{prefix} outcome", %{scope: scope} do
      {:ok, integration} = connect(scope, unquote(prefix) <> "secret")

      assert {:ok, validated} =
               APIKeyValidation.validate(scope, integration.id, integration.credential_generation,
                 client: FakeAPIKeyValidationClient
               )

      assert validated.validation_status == unquote(status)
      assert validated.validation_error_code == unquote(error_code)
      assert validated.credential_generation == integration.credential_generation
    end
  end

  for {provider, prefix, status, error_code} <- [
        {"anthropic", "valid-", "valid", nil},
        {"anthropic", "invalid-", "invalid", "invalid_credentials"},
        {"anthropic", "permission-", "unavailable", "provider_unavailable"},
        {"openrouter", "valid-", "valid", nil},
        {"openrouter", "invalid-", "invalid", "invalid_credentials"},
        {"openrouter", "permission-", "unavailable", "provider_unavailable"}
      ] do
    test "classifies #{provider} #{prefix} responses", %{scope: scope} do
      {:ok, integration} =
        connect(scope, unquote(prefix) <> "secret", unquote(provider))

      assert {:ok, validated} =
               APIKeyValidation.validate(scope, integration.id, integration.credential_generation,
                 client: FakeAPIKeyValidationClient
               )

      assert validated.validation_status == unquote(status)
      assert validated.validation_error_code == unquote(error_code)
    end
  end

  test "does not classify an unrecognized 401 context as an invalid key", %{scope: scope} do
    {:ok, integration} = connect(scope, "permission-secret")

    assert {:ok, validated} =
             APIKeyValidation.validate(scope, integration.id, integration.credential_generation,
               client: FakeAPIKeyValidationClient
             )

    assert validated.validation_status == "unavailable"
  end

  test "rejects stale work after replacement", %{scope: scope} do
    {:ok, original} = connect(scope, "valid-original")

    {:ok, _replacement} =
      Integrations.replace_credentials(
        scope,
        original.id,
        original.credential_generation,
        %{"api_key" => "valid-replacement"}
      )

    assert {:error, :stale_credential_generation} =
             APIKeyValidation.validate(scope, original.id, original.credential_generation,
               client: FakeAPIKeyValidationClient
             )
  end

  test "does not persist a result admitted before credential replacement", %{scope: scope} do
    Application.put_env(:kodo, :fake_api_key_validation_test_pid, self())

    on_exit(fn -> Application.delete_env(:kodo, :fake_api_key_validation_test_pid) end)

    {:ok, original} = connect(scope, "blocking-original")

    task =
      Task.async(fn ->
        APIKeyValidation.validate(scope, original.id, original.credential_generation,
          client: FakeAPIKeyValidationClient
        )
      end)

    assert_receive {:validation_probe_started, probe, _caller}

    {:ok, replacement} =
      Integrations.replace_credentials(
        scope,
        original.id,
        original.credential_generation,
        %{"api_key" => "valid-replacement"}
      )

    send(probe, {:finish_validation_probe, {:ok, 200, %{"data" => []}}})
    assert Task.await(task) == {:error, :stale_credential_generation}

    assert {:ok, current} = Integrations.get_integration(scope, original.id)
    assert current.credential_generation == replacement.credential_generation
    assert current.validation_status == "unverified"
  end

  test "does not persist a result admitted before disconnection", %{scope: scope} do
    Application.put_env(:kodo, :fake_api_key_validation_test_pid, self())

    on_exit(fn -> Application.delete_env(:kodo, :fake_api_key_validation_test_pid) end)

    {:ok, original} = connect(scope, "blocking-disconnect")

    task =
      Task.async(fn ->
        APIKeyValidation.validate(scope, original.id, original.credential_generation,
          client: FakeAPIKeyValidationClient
        )
      end)

    assert_receive {:validation_probe_started, probe, _caller}

    {:ok, disconnected} =
      Integrations.disconnect(scope, original.id, original.credential_generation)

    send(probe, {:finish_validation_probe, {:ok, 200, %{"data" => []}}})
    assert Task.await(task) == {:error, :stale_credential_generation}

    assert {:ok, current} = Integrations.get_integration(scope, original.id)
    assert current.credential_generation == disconnected.credential_generation
    assert current.connection_status == "disconnected"
    assert current.validation_status == "unverified"
  end

  test "bounds a validation client that never returns", %{scope: scope} do
    Application.put_env(:kodo, :fake_api_key_validation_test_pid, self())

    on_exit(fn -> Application.delete_env(:kodo, :fake_api_key_validation_test_pid) end)

    {:ok, integration} = connect(scope, "blocking-timeout")

    assert {:ok, validated} =
             APIKeyValidation.validate(scope, integration.id, integration.credential_generation,
               client: FakeAPIKeyValidationClient,
               timeout: 10
             )

    assert_receive {:validation_probe_started, probe, _caller}
    probe_ref = Process.monitor(probe)
    assert_receive {:DOWN, ^probe_ref, :process, ^probe, _reason}
    assert validated.validation_status == "unavailable"
    assert validated.validation_error_code == "timeout"
  end

  test "normalizes client exceptions before task logging", %{scope: scope} do
    secret = "must-not-reach-logs"
    {:ok, integration} = connect(scope, "raising-#{secret}")

    log =
      capture_log(fn ->
        assert {:ok, validated} =
                 APIKeyValidation.validate(
                   scope,
                   integration.id,
                   integration.credential_generation,
                   client: FakeAPIKeyValidationClient
                 )

        assert validated.validation_status == "unavailable"
        assert validated.validation_error_code == "provider_unavailable"
      end)

    refute log =~ secret
  end

  test "enforces ownership before decrypting or probing", %{scope: scope} do
    other_scope = AccountsFixtures.user_scope_fixture()
    {:ok, integration} = connect(scope, "valid-owned")

    assert {:error, :integration_not_found} =
             APIKeyValidation.validate(
               other_scope,
               integration.id,
               integration.credential_generation,
               client: FakeAPIKeyValidationClient
             )
  end

  defp connect(scope, api_key, provider \\ "openai") do
    Integrations.connect(scope, provider, "api_key", %{"api_key" => api_key})
  end
end
