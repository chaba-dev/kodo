defmodule Kodo.LLM.CredentialResolver do
  @moduledoc """
  Resolves a scoped integration reference into one operation-local credential.

  This Kodo-owned boundary deliberately wraps ReqLLM credential handling. ReqLLM
  supports process-wide keys, environment keys, and shared OAuth files; resolving
  here first prevents those fallbacks from selecting another user's credential.
  Only the resulting current access token or API key may cross into the adapter.
  """

  alias Kodo.Accounts.Scope
  alias Kodo.Integrations
  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.Integration
  alias Kodo.LLM.Credential
  alias Kodo.LLM.IntegrationRef

  @providers ~w(openai openai_codex anthropic openrouter)

  @doc false
  def resolve(
        %Scope{} = scope,
        %LLMDB.Model{provider: model_provider},
        %IntegrationRef{} = reference
      ) do
    provider = Atom.to_string(model_provider)

    with :ok <- require_supported_provider(provider),
         :ok <- require_reference(reference),
         {:ok, integration} <- Integrations.get_integration(scope, reference.integration_id),
         :ok <- require_generation(integration, reference.credential_generation),
         :ok <- require_provider(reference.provider, provider),
         :ok <- require_provider(integration.provider, provider),
         :ok <- require_usable(integration),
         {:ok, payload} <- CredentialEncryption.decrypt(integration),
         {:ok, credential} <- build_credential(integration, payload) do
      {:ok, credential}
    end
  end

  def resolve(_scope, _model, _reference), do: {:error, :invalid_integration_reference}

  defp require_supported_provider(provider) when provider in @providers, do: :ok
  defp require_supported_provider(_provider), do: {:error, :unsupported_model_provider}

  defp require_reference(%IntegrationRef{
         integration_id: id,
         provider: provider,
         credential_generation: generation
       })
       when is_binary(provider) and provider in @providers and is_integer(generation) and
              generation >= 0 do
    case Ecto.UUID.cast(id) do
      {:ok, _id} -> :ok
      :error -> {:error, :invalid_integration_reference}
    end
  end

  defp require_reference(%IntegrationRef{}), do: {:error, :invalid_integration_reference}

  defp require_provider(provider, provider), do: :ok
  defp require_provider(_actual, _expected), do: {:error, :integration_provider_mismatch}

  defp require_generation(%Integration{credential_generation: generation}, generation), do: :ok

  defp require_generation(%Integration{}, _generation),
    do: {:error, :stale_credential_generation}

  defp require_usable(%Integration{connection_status: "disconnected"}),
    do: {:error, :integration_disconnected}

  defp require_usable(%Integration{connection_status: "reauthorization_required"}),
    do: {:error, :integration_reauthorization_required}

  defp require_usable(%Integration{connection_status: "connected", validation_status: "invalid"}),
    do: {:error, :integration_invalid}

  defp require_usable(%Integration{connection_status: "connected"}), do: :ok

  defp build_credential(%Integration{authentication_type: "api_key"} = integration, payload) do
    with {:ok, api_key} <- fetch_secret(payload, "api_key") do
      {:ok, credential(integration, api_key, nil)}
    end
  end

  defp build_credential(
         %Integration{provider: "openai_codex", authentication_type: "oauth"} = integration,
         payload
       ) do
    with {:ok, access_token} <- fetch_secret(payload, "access_token"),
         {:ok, account_id} <- fetch_secret(payload, "account_id") do
      {:ok, credential(integration, access_token, account_id)}
    end
  end

  defp build_credential(%Integration{}, _payload),
    do: {:error, :credential_payload_invalid}

  defp credential(integration, token, account_id) do
    %Credential{
      integration_id: integration.id,
      provider: integration.provider,
      authentication_type: integration.authentication_type,
      credential_generation: integration.credential_generation,
      billing_path: billing_path(integration.provider),
      token: token,
      account_id: account_id
    }
  end

  defp fetch_secret(payload, field) do
    case payload[field] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :credential_payload_invalid}
    end
  end

  defp billing_path("openai_codex"), do: :subscription
  defp billing_path("openrouter"), do: :aggregator
  defp billing_path(_provider), do: :platform
end
