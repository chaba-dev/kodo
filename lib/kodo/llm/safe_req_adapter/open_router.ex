defmodule Kodo.LLM.SafeReqAdapter.OpenRouter do
  @moduledoc false

  def run(request), do: Kodo.LLM.SafeReqAdapter.run(request, "openrouter")
end
