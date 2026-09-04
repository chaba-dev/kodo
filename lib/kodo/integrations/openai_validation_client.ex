defmodule Kodo.Integrations.OpenAIValidationClient do
  @moduledoc false

  @callback get_models(api_key :: String.t()) ::
              {:ok, status :: non_neg_integer(), body :: term()}
              | {:error, :network_error | :timeout | :tls_error | :redirect}
end
