defmodule Kodo.LLM.SafeReqAdapter.OpenAICodex do
  @moduledoc false

  def run(request), do: Kodo.LLM.SafeReqAdapter.run(request, "openai_codex")
end
