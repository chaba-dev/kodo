defmodule Kodo.LLM.SafeTransportError do
  @moduledoc false

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: :network}), do: "provider transport unavailable"
  def message(%__MODULE__{}), do: "provider transport failed"
end
