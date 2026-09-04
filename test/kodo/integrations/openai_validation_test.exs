defmodule Kodo.Integrations.OpenAIValidationTest do
  use Kodo.DataCase, async: true

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
        {"permission-", "unavailable", "provider_unavailable"},
        {"timeout-", "unavailable", "timeout"}
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
