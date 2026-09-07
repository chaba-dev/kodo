defmodule Kodo.Integrations.APIKeyValidationClient do
  @moduledoc false

  @callback get_metadata(provider :: String.t(), api_key :: String.t()) ::
              {:ok, status :: non_neg_integer(), body :: term()}
              | {:error, :network_error | :timeout | :tls_error | :redirect}
end
