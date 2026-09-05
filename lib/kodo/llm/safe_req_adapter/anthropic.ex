defmodule Kodo.LLM.SafeReqAdapter.Anthropic do
  @moduledoc false

  def run(request), do: Kodo.LLM.SafeReqAdapter.run(request, "anthropic")
end
