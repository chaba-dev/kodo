defmodule Kodo.LLM.ProviderError do
  @moduledoc "A credential-free, user-actionable model-provider failure."

  @enforce_keys [:kind, :provider, :model, :billing_path, :retryable]
  defstruct [:kind, :provider, :model, :billing_path, :retryable]

  @type kind ::
          :integration_required
          | :integration_changed
          | :authentication_rejected
          | :billing_required
          | :access_restricted
          | :quota_or_rate_limit
          | :provider_unavailable
          | :request_failed

  @type t :: %__MODULE__{
          kind: kind(),
          provider: String.t(),
          model: String.t(),
          billing_path: :platform | :subscription | :aggregator,
          retryable: boolean()
        }

  def from_integration(reason, %LLMDB.Model{} = model)
      when reason in [
             :integration_not_found,
             :integration_disconnected,
             :integration_reauthorization_required,
             :integration_invalid,
             :stale_credential_generation
           ] do
    provider = Atom.to_string(model.provider)

    %__MODULE__{
      kind: integration_kind(reason),
      provider: provider,
      model: "#{provider}:#{model.id}",
      billing_path: billing_path(provider),
      retryable: false
    }
  end

  def guidance(%__MODULE__{kind: :integration_required, provider: provider}),
    do: "Connect the #{provider_name(provider)} integration, then retry the turn."

  def guidance(%__MODULE__{kind: :integration_changed}),
    do:
      "The provider credential changed during this turn. Retry the turn with its current connection."

  def guidance(%__MODULE__{kind: :authentication_rejected}),
    do: "Replace or reconnect this provider credential, then retry the turn."

  def guidance(%__MODULE__{kind: :billing_required}),
    do: "Update billing with this provider, then retry the turn."

  def guidance(%__MODULE__{kind: :access_restricted}),
    do: "Check this provider account's model access, quota, and billing, then retry the turn."

  def guidance(%__MODULE__{kind: :quota_or_rate_limit}),
    do: "Check this provider's quota or wait for its rate limit to reset, then retry the turn."

  def guidance(%__MODULE__{kind: :provider_unavailable}),
    do: "The provider is temporarily unavailable. Retry the turn later."

  def guidance(%__MODULE__{kind: :request_failed}),
    do: "The provider could not complete this model request. Review provider access, then retry."

  defp integration_kind(:integration_invalid), do: :authentication_rejected
  defp integration_kind(:integration_reauthorization_required), do: :authentication_rejected
  defp integration_kind(:stale_credential_generation), do: :integration_changed
  defp integration_kind(_reason), do: :integration_required

  defp billing_path("openai_codex"), do: :subscription
  defp billing_path("openrouter"), do: :aggregator
  defp billing_path(_provider), do: :platform

  defp provider_name("openai"), do: "OpenAI API"
  defp provider_name("anthropic"), do: "Anthropic"
  defp provider_name("openrouter"), do: "OpenRouter"
  defp provider_name("openai_codex"), do: "ChatGPT"
  defp provider_name(provider), do: provider
end
