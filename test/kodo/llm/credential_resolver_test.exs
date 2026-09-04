defmodule Kodo.LLM.CredentialResolverTest do
  use Kodo.DataCase, async: true

  alias Kodo.AccountsFixtures
  alias Kodo.Integrations
  alias Kodo.LLM
  alias Kodo.LLM.CredentialResolver
  alias Kodo.LLM.IntegrationRef

  setup do
    scope = AccountsFixtures.user_scope_fixture()

    {:ok, integration} =
      Integrations.connect(scope, "openai", "api_key", %{"api_key" => "scoped-secret"})

    %{
      scope: scope,
      integration: integration,
      reference: IntegrationRef.from_integration(integration)
    }
  end

  test "resolves only the referenced owned credential for a matching model", context do
    assert {:ok, credential} = resolve(context)
    assert credential.integration_id == context.integration.id
    assert credential.provider == "openai"
    assert credential.authentication_type == "api_key"
    assert credential.credential_generation == context.integration.credential_generation
    assert credential.billing_path == :platform
    assert credential.token == "scoped-secret"
    assert credential.account_id == nil
    refute inspect(credential) =~ "scoped-secret"
  end

  test "the public facade rejects credential options and stale preflight references", context do
    assert {:ok, resolved_model, reference} =
             LLM.resolve_integration(context.scope, "openai:gpt-4o-mini")

    assert {:error, :credential_options_not_allowed} =
             LLM.generate(
               context.scope,
               resolved_model,
               reference,
               [%{"role" => "user", "content" => "final answer"}],
               [],
               adapter: Kodo.Test.FakeLLM,
               timeout: 1_000,
               api_key: "caller-secret"
             )

    assert {:ok, _replaced} =
             Integrations.replace_credentials(
               context.scope,
               context.integration.id,
               context.integration.credential_generation,
               %{"api_key" => "replacement"}
             )

    assert {:error, :stale_credential_generation} =
             LLM.generate(
               context.scope,
               resolved_model,
               reference,
               [%{"role" => "user", "content" => "final answer"}],
               [],
               adapter: Kodo.Test.FakeLLM,
               timeout: 1_000
             )
  end

  test "rejects forged and cross-user references", context do
    other_scope = AccountsFixtures.user_scope_fixture()

    assert {:error, :integration_not_found} =
             resolve(%{context | scope: other_scope})

    forged = %{context.reference | integration_id: Ecto.UUID.generate()}
    assert {:error, :integration_not_found} = resolve(%{context | reference: forged})
  end

  test "rejects stale references after replacement or disconnection", context do
    assert {:ok, replaced} =
             Integrations.replace_credentials(
               context.scope,
               context.integration.id,
               context.integration.credential_generation,
               %{"api_key" => "replacement"}
             )

    assert {:error, :stale_credential_generation} = resolve(context)

    replacement_reference = IntegrationRef.from_integration(replaced)

    assert {:ok, _disconnected} =
             Integrations.disconnect(
               context.scope,
               replaced.id,
               replaced.credential_generation
             )

    assert {:error, :stale_credential_generation} =
             resolve(%{context | reference: replacement_reference})
  end

  test "rejects disconnected and confirmed-invalid integrations", context do
    assert {:ok, disconnected} =
             Integrations.disconnect(
               context.scope,
               context.integration.id,
               context.integration.credential_generation
             )

    assert {:error, :integration_disconnected} =
             resolve(%{context | reference: IntegrationRef.from_integration(disconnected)})

    other_scope = AccountsFixtures.user_scope_fixture()

    assert {:ok, invalid} =
             Integrations.connect(other_scope, "openai", "api_key", %{"api_key" => "invalid"})

    assert {:ok, invalid} =
             Integrations.validation_invalid(
               other_scope,
               invalid.id,
               invalid.credential_generation
             )

    assert {:error, :integration_invalid} =
             resolve(%{
               context
               | scope: other_scope,
                 integration: invalid,
                 reference: IntegrationRef.from_integration(invalid)
             })
  end

  test "admits unverified and validation-unavailable integrations", context do
    assert {:ok, _credential} = resolve(context)

    assert {:ok, unavailable} =
             Integrations.validation_unavailable(
               context.scope,
               context.integration.id,
               context.integration.credential_generation,
               "timeout"
             )

    assert {:ok, _credential} =
             resolve(%{context | reference: IntegrationRef.from_integration(unavailable)})
  end

  test "captures only usable integration metadata during preflight", context do
    assert {:ok, reference} = CredentialResolver.reference(context.scope, model())
    assert reference == context.reference

    assert {:ok, invalid} =
             Integrations.validation_invalid(
               context.scope,
               context.integration.id,
               context.integration.credential_generation
             )

    assert {:error, :integration_invalid} =
             CredentialResolver.reference(context.scope, model())

    assert invalid.credential_generation == reference.credential_generation
  end

  test "requires exact model, reference, and stored providers", context do
    anthropic_model = LLMDB.Model.new!(%{id: "claude", provider: :anthropic})

    assert {:error, :integration_provider_mismatch} =
             CredentialResolver.resolve(context.scope, anthropic_model, context.reference)

    forged = %{context.reference | provider: "anthropic"}

    assert {:error, :integration_provider_mismatch} =
             resolve(%{context | reference: forged})

    unsupported_model = LLMDB.Model.new!(%{id: "local", provider: :ollama})

    assert {:error, :unsupported_model_provider} =
             CredentialResolver.resolve(context.scope, unsupported_model, context.reference)
  end

  test "rejects forged authentication and billing provenance", context do
    forged_authentication = %{context.reference | authentication_type: "oauth"}

    assert {:error, :integration_authentication_mismatch} =
             resolve(%{context | reference: forged_authentication})

    forged_billing = %{context.reference | billing_path: :subscription}

    assert {:error, :integration_billing_mismatch} =
             resolve(%{context | reference: forged_billing})
  end

  test "rejects malformed decrypted payloads with a bounded error" do
    other_scope = AccountsFixtures.user_scope_fixture()

    assert {:ok, malformed} =
             Integrations.connect(other_scope, "openai", "api_key", %{"unexpected" => "secret"})

    assert {:error, :credential_payload_invalid} =
             CredentialResolver.resolve(
               other_scope,
               model(),
               IntegrationRef.from_integration(malformed)
             )
  end

  test "resolves Codex access and account identity without exposing refresh state" do
    scope = AccountsFixtures.user_scope_fixture()

    integration = %Kodo.Integrations.Integration{
      id: Ecto.UUID.generate(),
      user_id: scope.user.id,
      provider: "openai_codex",
      authentication_type: "oauth"
    }

    integration = Kodo.Repo.insert!(integration)

    assert {:ok, connected} =
             Integrations.oauth_succeeded(scope, integration.id, 0, %{
               "access_token" => "access-secret",
               "refresh_token" => "refresh-secret",
               "account_id" => "account-secret"
             })

    codex_model = LLMDB.Model.new!(%{id: "codex", provider: :openai_codex})

    assert {:ok, credential} =
             CredentialResolver.resolve(
               scope,
               codex_model,
               IntegrationRef.from_integration(connected)
             )

    assert credential.token == "access-secret"
    assert credential.account_id == "account-secret"
    assert credential.billing_path == :subscription
    inspected = inspect(credential)
    refute inspected =~ "access-secret"
    refute inspected =~ "refresh-secret"
    refute inspected =~ "account-secret"
  end

  defp resolve(context) do
    CredentialResolver.resolve(context.scope, model(), context.reference)
  end

  defp model, do: LLMDB.Model.new!(%{id: "gpt", provider: :openai})
end
