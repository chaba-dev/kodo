defmodule Kodo.LLM.SafeReqAdapter.OpenAI do
  @moduledoc false

  def run(request), do: Kodo.LLM.SafeReqAdapter.run(request, "openai")
end
