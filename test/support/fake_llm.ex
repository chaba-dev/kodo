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
       "structured_output" => capabilities.structured_output in [:json_schema, :object],
       "required_context_window" => capabilities.min_context,
       "tools" => capabilities.tools
     }}
  end

  @impl true
  def generate(model, messages, tools, _credential, opts) do
    last = List.last(messages)

    force_final_turn? =
      Enum.any?(messages, &(&1["role"] == "user" and &1["content"] == "force final turn"))

    if force_final_turn? and tools == [] do
      test_pid = Application.fetch_env!(:kodo, :fake_llm_test_pid)
      send(test_pid, {:final_turn_tools, tools})
      final("Finished before the budget expired.")
    else
      generate_response(model, messages, tools, opts, last)
    end
  end

  defp generate_response(model, messages, tools, opts, last) do
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

  @impl true
  def generate_object(_model, messages, _schema, _credential, _opts) do
    if test_pid = Application.get_env(:kodo, :fake_llm_review_pid) do
      send(test_pid, {:review_messages, messages})
    end

    diff = List.last(messages)["content"]

    object =
      if String.contains?(diff, "REVIEW_FINDING") do
        %{
          "clean" => false,
          "findings" => [
            %{
              "severity" => "high",
              "path" => "lib/example.ex",
              "line" => 7,
              "explanation" => "The diff contains a regression marker.",
              "suggested_fix" => "Remove the regression marker."
            }
          ]
        }
      else
        %{"clean" => true, "findings" => []}
      end

    {:ok, %{object: object, usage: %{total_tokens: @small_usage_tokens}}}
  end

  defp initial(%{"content" => "ownership barrier"}) do
    test_pid = Application.fetch_env!(:kodo, :fake_llm_test_pid)
    send(test_pid, {:model_dispatch_started, self()})

    receive do
      :release_model_dispatch -> final("Released")
    end
  end

  defp initial(%{"content" => "capture contract"}), do: final("The fix is complete.")
  defp initial(%{"content" => "final answer"}), do: final("Ready for review.")

  defp initial(%{"content" => "force final turn"}) do
    tool_call(
      "force-final-turn-patch",
      "apply_patch",
      %{"patch" => "--- a/example.txt\n+++ b/example.txt\n@@ -1 +1 @@\n-before\n+after\n"}
    )
  end

  defp initial(%{"content" => "Final-diff review found supported issues." <> _findings}),
    do: final("Addressed review findings.")

  defp initial(%{"content" => @full_stack_prompt}) do
    tool_call(
      "e2e-patch",
      "apply_patch",
      %{
        "patch" => "--- a/greeting.txt\n+++ b/greeting.txt\n@@ -1 +1 @@\n-helo\n+hello\n"
      }
    )
  end

  defp initial(%{"content" => "wait"}) do
    if test_pid = Application.get_env(:kodo, :fake_llm_test_pid) do
      send(test_pid, :fake_llm_waiting)
    end

    receive do
      :never -> {:error, :unexpected}
    end
  end

  defp initial(%{"content" => "provider failure"}), do: {:error, :provider_failure}
  defp initial(%{"content" => "provider timeout"}), do: {:error, :provider_timeout}

  defp initial(%{"content" => "provider quota"}) do
    {:error,
     %Kodo.LLM.ProviderError{
       kind: :quota_or_rate_limit,
       provider: "openai",
       model: "openai:gpt-4o-mini",
       billing_path: :platform,
       retryable: true
     }}
  end

  defp initial(%{"content" => "delegate search"}) do
    tool_call("delegate-search", "delegate_search", %{"question" => "find helper"})
  end

  defp initial(%{"content" => "delegate unsafe search"}) do
    tool_call("delegate-unsafe-search", "delegate_search", %{"question" => "mutate code"})
  end

  defp initial(%{"content" => "find helper"}) do
    tool_call(
      "search-read",
      "read_file",
      %{"path" => "README.md", "offset" => 0, "limit" => @read_file_limit_bytes}
    )
  end

  defp initial(%{"content" => "mutate code"}) do
    tool_call(
      "search-mutation",
      "apply_patch",
      %{"patch" => "*** Begin Patch\n*** End Patch"}
    )
  end

  defp initial(%{"content" => "token budget"}) do
    {:ok,
     %{
       type: :final_answer,
       text: "Too expensive",
       tool_calls: [],
       usage: %{total_tokens: @over_budget_usage_tokens}
     }}
  end

  defp initial(message) do
    case message do
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

  defp continue_from(
         %{"role" => "tool", "name" => "read_file", "content" => output},
         messages
       ) do
    content = output["content"] || output[:content]

    cond do
      hd(messages)["content"] == Kodo.Agent.Roles.fetch!(:search).prompt ->
        if test_pid = Application.get_env(:kodo, :fake_llm_search_resume_pid) do
          send(test_pid, :search_continuation_started)

          receive do
            :release_search_continuation -> :ok
          end
        end

        final("README.md:1 contains the requested helper evidence.")

      String.trim(content) == "hello" ->
        tool_call("e2e-diff", "git_diff", %{"paths" => ["greeting.txt"]})

      true ->
        {:error, {:unexpected_file_content, content}}
    end
  end

  defp continue_from(%{"role" => "tool", "name" => "delegate_search"}, _messages) do
    final("Used delegated evidence.")
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
