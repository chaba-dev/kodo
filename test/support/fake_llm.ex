defmodule Kodo.Test.FakeLLM do
  @moduledoc false

  @behaviour Kodo.LLM

  @full_stack_prompt "KODO_HERMETIC_FULL_STACK_FIX_GREETING"
  @read_file_limit_bytes 1_024
  @small_usage_tokens 5
  @standard_usage_tokens 10
  @over_budget_usage_tokens 101

  @impl true
  def validate_model(model, _role_mapping, contract) do
    capabilities =
      Map.get(contract, :capabilities, %{
        tools: true,
        structured_output: false,
        min_context: 1,
        input_modalities: [:text]
      })

    {:ok,
     %{
       "catalog_model" => model,
       "context_window" => capabilities.min_context,
       "input_modalities" => Enum.map(capabilities.input_modalities, &to_string/1),
       "json_schema" => capabilities.structured_output == :json_schema,
       "required_context_window" => capabilities.min_context,
       "tools" => capabilities.tools
     }}
  end

  @impl true
  def generate(model, messages, tools, opts) do
    last = List.last(messages)

    if last["content"] == "capture contract" do
      test_pid = Application.fetch_env!(:kodo, :fake_llm_test_pid)
      send(test_pid, {:llm_request, model, hd(messages), tools, opts})
    end

    if last["role"] == "tool" do
      continue_from(last, messages)
    else
      initial(last)
    end
  end

  defp initial(%{"content" => "ownership barrier"}) do
    test_pid = Application.fetch_env!(:kodo, :fake_llm_test_pid)
    send(test_pid, {:model_dispatch_started, self()})

    receive do
      :release_model_dispatch -> final("Released")
    end
  end

  defp initial(%{"content" => "capture contract"}), do: final("The fix is complete.")

  defp initial(message) do
    case message do
      %{"content" => @full_stack_prompt} ->
        tool_call(
          "e2e-patch",
          "apply_patch",
          %{
            "patch" => "--- a/greeting.txt\n+++ b/greeting.txt\n@@ -1 +1 @@\n-helo\n+hello\n"
          }
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

      %{"content" => "duplicate tool ids"} ->
        {:ok,
         %{
           type: :tool_calls,
           text: "",
           tool_calls: [
             %{
               id: "duplicate",
               name: "apply_patch",
               arguments: %{"patch" => "*** Begin Patch\n*** End Patch"}
             },
             %{
               id: "duplicate",
               name: "apply_patch",
               arguments: %{"patch" => "*** Begin Patch\n*** End Patch"}
             }
           ],
           usage: %{total_tokens: @standard_usage_tokens}
         }}

      %{"content" => "multiple tools"} ->
        {:ok,
         %{
           type: :tool_calls,
           text: "",
           tool_calls: [
             %{
               id: "first",
               name: "apply_patch",
               arguments: %{"patch" => "*** Begin Patch\n*** End Patch"}
             },
             %{id: "second", name: "read_file", arguments: %{"path" => "README.md"}}
           ],
           usage: %{total_tokens: @standard_usage_tokens}
         }}

      %{"content" => "token budget"} ->
        {:ok,
         %{
           type: :final_answer,
           text: "Too expensive",
           tool_calls: [],
           usage: %{total_tokens: @over_budget_usage_tokens}
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
           usage: %{total_tokens: @standard_usage_tokens}
         }}
    end
  end

  defp continue_from(%{"role" => "tool", "name" => "apply_patch"}, messages) do
    if Enum.any?(messages, &match?(%{"content" => @full_stack_prompt}, &1)) do
      tool_call(
        "e2e-read",
        "read_file",
        %{"path" => "greeting.txt", "offset" => 0, "limit" => @read_file_limit_bytes}
      )
    else
      final("The fix is complete.")
    end
  end

  defp continue_from(%{"role" => "tool", "name" => "read_file", "content" => output}, _messages) do
    content = output["content"] || output[:content]

    if String.trim(content) == "hello" do
      tool_call("e2e-diff", "git_diff", %{"paths" => ["greeting.txt"]})
    else
      {:error, {:unexpected_file_content, content}}
    end
  end

  defp continue_from(%{"role" => "tool", "name" => "git_diff"}, _messages) do
    final("Greeting corrected and repository evidence verified.")
  end

  defp final(text) do
    {:ok,
     %{
       type: :final_answer,
       text: text,
       tool_calls: [],
       usage: %{total_tokens: @small_usage_tokens}
     }}
  end

  defp tool_call(id, name, arguments) do
    {:ok,
     %{
       type: :tool_calls,
       text: "",
       tool_calls: [%{id: id, name: name, arguments: arguments}],
       usage: %{total_tokens: @small_usage_tokens}
     }}
  end
end
