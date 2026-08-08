defmodule Kodo.Test.FakeLLM do
  @moduledoc false

  @behaviour Kodo.LLM

  @full_stack_prompt "KODO_HERMETIC_FULL_STACK_FIX_GREETING"
  @read_file_limit_bytes 1_024
  @small_usage_tokens 5
  @standard_usage_tokens 10
  @over_budget_usage_tokens 101

  @impl true
  def generate(_model, messages, _tools, _opts) do
    case List.last(messages) do
      %{"content" => @full_stack_prompt} ->
        tool_call(
          "e2e-patch",
          "apply_patch",
          %{
            "patch" => "--- a/greeting.txt\n+++ b/greeting.txt\n@@ -1 +1 @@\n-helo\n+hello\n"
          },
          :e2e_read_file
        )

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
           usage: %{total_tokens: @over_budget_usage_tokens},
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
           usage: %{total_tokens: @standard_usage_tokens},
           continuation: :first
         }}
    end
  end

  @impl true
  def continue(_model, :e2e_read_file, [%{output: _output}], _tools, _opts) do
    tool_call(
      "e2e-read",
      "read_file",
      %{"path" => "greeting.txt", "offset" => 0, "limit" => @read_file_limit_bytes},
      :e2e_git_diff
    )
  end

  def continue(_model, :e2e_git_diff, [%{output: output}], _tools, _opts) do
    content = output["content"] || output[:content]

    if String.trim(content) == "hello" do
      tool_call(
        "e2e-diff",
        "git_diff",
        %{"paths" => ["greeting.txt"]},
        :e2e_final
      )
    else
      {:error, {:unexpected_file_content, content}}
    end
  end

  def continue(_model, :e2e_final, [%{output: _output}], _tools, _opts) do
    {:ok,
     %{
       type: :final_answer,
       text: "Greeting corrected and repository evidence verified.",
       tool_calls: [],
       usage: %{total_tokens: @small_usage_tokens},
       continuation: :done
     }}
  end

  def continue(_model, :first, [%{output: output}], _tools, _opts) do
    {:ok,
     %{
       type: :final_answer,
       text: "The fix is complete.",
       tool_calls: [],
       usage: %{total_tokens: @small_usage_tokens},
       continuation: output
     }}
  end

  defp tool_call(id, name, arguments, continuation) do
    {:ok,
     %{
       type: :tool_calls,
       text: "",
       tool_calls: [%{id: id, name: name, arguments: arguments}],
       usage: %{total_tokens: @small_usage_tokens},
       continuation: continuation
     }}
  end
end
