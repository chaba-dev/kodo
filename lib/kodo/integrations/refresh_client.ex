defmodule Kodo.Integrations.RefreshClient do
  @moduledoc false

  @callback refresh(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
end
