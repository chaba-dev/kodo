defmodule Kodo.LLM.ProviderError do
  @moduledoc "A credential-free, user-actionable model-provider failure."

  @enforce_keys [:kind, :provider, :model, :billing_path, :retryable]
  defstruct [:kind, :provider, :model, :billing_path, :retryable]

  @type kind ::
          :authentication_rejected
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
end
