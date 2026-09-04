defmodule Kodo.LLM.Credential do
  @moduledoc false

  @derive {Inspect,
           only: [
             :integration_id,
             :provider,
             :authentication_type,
             :credential_generation,
             :billing_path
           ]}
  @enforce_keys [
    :integration_id,
    :provider,
    :authentication_type,
    :credential_generation,
    :billing_path,
    :token
  ]
  defstruct [
    :integration_id,
    :provider,
    :authentication_type,
    :credential_generation,
    :billing_path,
    :token,
    :account_id
  ]

  @opaque t :: %__MODULE__{
            integration_id: Ecto.UUID.t(),
            provider: String.t(),
            authentication_type: String.t(),
            credential_generation: non_neg_integer(),
            billing_path: :platform | :subscription | :aggregator,
            token: String.t(),
            account_id: String.t() | nil
          }
end
