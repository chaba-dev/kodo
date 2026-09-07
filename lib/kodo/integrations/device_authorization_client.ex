defmodule Kodo.Integrations.DeviceAuthorizationClient do
  @moduledoc false

  @callback create(keyword()) ::
              {:ok,
               %{
                 payload: map(),
                 polling_interval_ms: non_neg_integer(),
                 verification_url: String.t()
               }}
              | {:error, atom()}
  @callback poll(map(), keyword()) :: {:ok, map()} | :pending | {:error, atom()}
  @callback exchange(map(), keyword()) :: {:ok, map()} | {:error, atom()}
end
