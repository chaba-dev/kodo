defmodule Kodo.LLM.ReqLLM do
  @moduledoc "ReqLLM provider adapter that exposes only normalized Kodo values."

  @behaviour Kodo.LLM

  alias ReqLLM.Context
  alias ReqLLM.Response
  alias ReqLLM.Tool

  @impl true
  def generate(model, messages, tools, opts) do
    context = messages |> Enum.map(&message/1) |> Context.new()
    request(model, context, tools, opts)
  end

  @impl true
  def continue(model, continuation, results, tools, opts) do
    tool_results =
      Enum.map(results, fn result ->
        Context.tool_result(result.tool_call_id, result.name, result.output)
      end)

    with {:ok, context} <-
           Context.append_tool_exchange(
             continuation.context,
             continuation.response,
             tool_results
           ) do
      request(model, context, tools, opts)
    end
  end

  @doc false
  def build_tools(tools) do
    Enum.map(tools, fn tool ->
      Tool.new!(
        name: tool.name,
        description: tool.description,
        parameter_schema: tool.parameters,
        callback: &unused_callback/1,
        strict: true
      )
    end)
  end

  defp request(model, context, tools, opts) do
    request_opts =
      [
        tools: build_tools(tools),
        receive_timeout: Keyword.fetch!(opts, :timeout),
        total_timeout: Keyword.fetch!(opts, :timeout)
      ]

    with {:ok, response} <- ReqLLM.generate_text(model, context, request_opts) do
      classified = Response.classify(response)

      {:ok,
       %{
         type: classified.type,
         text: classified.text,
         tool_calls: classified.tool_calls,
         usage: Response.usage(response),
         continuation: %{context: context, response: response}
       }}
    end
  end

  defp message(%{"role" => "system", "content" => content}), do: Context.system(content)
  defp message(%{"role" => "user", "content" => content}), do: Context.user(content)
  defp message(%{"role" => "assistant", "content" => content}), do: Context.assistant(content)

  defp unused_callback(_arguments), do: {:error, :execution_owned_by_kodo}
end
