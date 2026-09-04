defmodule Kodo.Integrations.OpenAIValidationTest do
  use Kodo.DataCase, async: false

  alias Kodo.AccountsFixtures
  alias Kodo.Integrations
  alias Kodo.Integrations.OpenAIValidation
  alias Kodo.Test.FakeOpenAIValidationClient

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
               OpenAIValidation.validate(scope, integration.id, integration.credential_generation,
                 client: FakeOpenAIValidationClient
               )

      assert validated.validation_status == unquote(status)
      assert validated.validation_error_code == unquote(error_code)
      assert validated.credential_generation == integration.credential_generation
    end
  end

  test "does not classify an unrecognized 401 context as an invalid key", %{scope: scope} do
    {:ok, integration} = connect(scope, "permission-secret")

    assert {:ok, validated} =
             OpenAIValidation.validate(scope, integration.id, integration.credential_generation,
               client: FakeOpenAIValidationClient
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
             OpenAIValidation.validate(scope, original.id, original.credential_generation,
               client: FakeOpenAIValidationClient
             )
  end

  test "does not persist a result admitted before credential replacement", %{scope: scope} do
    Application.put_env(:kodo, :fake_openai_validation_test_pid, self())

    on_exit(fn -> Application.delete_env(:kodo, :fake_openai_validation_test_pid) end)

    {:ok, original} = connect(scope, "blocking-original")

    task =
      Task.async(fn ->
        OpenAIValidation.validate(scope, original.id, original.credential_generation,
          client: FakeOpenAIValidationClient
        )
      end)

    assert_receive {:validation_probe_started, probe}

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
    Application.put_env(:kodo, :fake_openai_validation_test_pid, self())

    on_exit(fn -> Application.delete_env(:kodo, :fake_openai_validation_test_pid) end)

    {:ok, original} = connect(scope, "blocking-disconnect")

    task =
      Task.async(fn ->
        OpenAIValidation.validate(scope, original.id, original.credential_generation,
          client: FakeOpenAIValidationClient
        )
      end)

    assert_receive {:validation_probe_started, probe}

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
    Application.put_env(:kodo, :fake_openai_validation_test_pid, self())

    on_exit(fn -> Application.delete_env(:kodo, :fake_openai_validation_test_pid) end)

    {:ok, integration} = connect(scope, "blocking-timeout")

    assert {:ok, validated} =
             OpenAIValidation.validate(scope, integration.id, integration.credential_generation,
               client: FakeOpenAIValidationClient,
               timeout: 10
             )

    assert_receive {:validation_probe_started, probe}
    probe_ref = Process.monitor(probe)
    assert_receive {:DOWN, ^probe_ref, :process, ^probe, _reason}
    assert validated.validation_status == "unavailable"
    assert validated.validation_error_code == "timeout"
  end

  test "enforces ownership before decrypting or probing", %{scope: scope} do
    other_scope = AccountsFixtures.user_scope_fixture()
    {:ok, integration} = connect(scope, "valid-owned")

    assert {:error, :integration_not_found} =
             OpenAIValidation.validate(
               other_scope,
               integration.id,
               integration.credential_generation,
               client: FakeOpenAIValidationClient
             )
  end

  defp connect(scope, api_key) do
    Integrations.connect(scope, "openai", "api_key", %{"api_key" => api_key})
  end
end
