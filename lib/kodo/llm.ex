defmodule Kodo.LLM do
  @moduledoc "Provider-independent boundary for one explicit primary-agent model step."

  @type tool :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:parameters) => map()
        }

  @type result :: %{
          required(:type) => :final_answer | :tool_calls,
          required(:text) => String.t(),
          required(:tool_calls) => [map()],
          required(:usage) => map() | nil,
          optional(:assistant) => map()
        }

  @callback generate(String.t(), [map()], [tool()], keyword()) ::
              {:ok, result()} | {:error, term()}

  def adapter, do: Application.get_env(:kodo, :llm_adapter, Kodo.LLM.ReqLLM)
end
