defmodule Kodo.LLM.IntegrationRef do
  @moduledoc """
  Non-secret reference to one generation of a user-owned provider integration.

  Generation is part of the reference so replacing or disconnecting credentials
  invalidates references captured by earlier preflight work.
  """

  alias Kodo.Integrations.Integration

  @enforce_keys [
    :integration_id,
    :provider,
    :authentication_type,
    :credential_generation,
    :billing_path
  ]
  defstruct [
    :integration_id,
    :provider,
    :authentication_type,
    :credential_generation,
    :billing_path
  ]

  @opaque t :: %__MODULE__{
            integration_id: Ecto.UUID.t(),
            provider: String.t(),
            authentication_type: String.t(),
            credential_generation: non_neg_integer(),
            billing_path: :platform | :subscription | :aggregator
          }

  @doc "Builds a reference from scoped integration metadata."
  def from_integration(%Integration{} = integration) do
    %__MODULE__{
      integration_id: integration.id,
      provider: integration.provider,
      authentication_type: integration.authentication_type,
      credential_generation: integration.credential_generation,
      billing_path: billing_path(integration.provider)
    }
  end

  defp billing_path("openai_codex"), do: :subscription
  defp billing_path("openrouter"), do: :aggregator
  defp billing_path(_provider), do: :platform
end
