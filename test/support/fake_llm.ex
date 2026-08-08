defmodule Kodo.Test.FakeLLM do
  @moduledoc false

  @behaviour Kodo.LLM

  @impl true
  def generate(_model, messages, _tools, _opts) do
    case List.last(messages) do
      %{"content" => "wait"} ->
        if test_pid = Application.get_env(:kodo, :fake_llm_test_pid) do
          send(test_pid, :fake_llm_waiting)
        end

        receive do
          :never -> {:error, :unexpected}
        end

      %{"content" => "provider failure"} ->
        {:error, :provider_failure}

      %{"content" => "token budget"} ->
        {:ok,
         %{
           type: :final_answer,
           text: "Too expensive",
           tool_calls: [],
           usage: %{total_tokens: 101},
           continuation: :done
         }}

      _message ->
        {:ok,
         %{
           type: :tool_calls,
           text: "",
           tool_calls: [
             %{
               id: "call-1",
               name: "apply_patch",
               arguments: %{"patch" => "*** Begin Patch\n*** End Patch"}
             }
           ],
           usage: %{total_tokens: 10},
           continuation: :first
         }}
    end
  end

  @impl true
  def continue(_model, :first, [%{output: output}], _tools, _opts) do
    {:ok,
     %{
       type: :final_answer,
       text: "The fix is complete.",
       tool_calls: [],
       usage: %{total_tokens: 5},
       continuation: output
     }}
  end
end
