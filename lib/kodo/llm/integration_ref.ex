defmodule Kodo.LLM.IntegrationRef do
  @moduledoc """
  Non-secret reference to one generation of a user-owned provider integration.

  Generation is part of the reference so replacing or disconnecting credentials
  invalidates references captured by earlier preflight work.
  """

  alias Kodo.Integrations.Integration

  @enforce_keys [:integration_id, :provider, :credential_generation]
  defstruct [:integration_id, :provider, :credential_generation]

  @opaque t :: %__MODULE__{
            integration_id: Ecto.UUID.t(),
            provider: String.t(),
            credential_generation: non_neg_integer()
          }

  @doc "Builds a reference from scoped integration metadata."
  def from_integration(%Integration{} = integration) do
    %__MODULE__{
      integration_id: integration.id,
      provider: integration.provider,
      credential_generation: integration.credential_generation
    }
  end
end
