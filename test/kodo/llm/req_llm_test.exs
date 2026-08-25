defmodule Kodo.LLM.ReqLLMTest do
  use ExUnit.Case, async: true

  alias Kodo.LLM.ReqLLM, as: Adapter

  test "translates Kodo tool definitions into strict ReqLLM tools" do
    [tool] =
      Adapter.build_tools([
        %{
          name: "read_file",
          description: "Read a bounded file range",
          parameters: %{
            "type" => "object",
            "properties" => %{"path" => %{"type" => "string"}},
            "required" => ["path"],
            "additionalProperties" => false
          }
        }
      ])

    assert tool.name == "read_file"
    assert tool.strict
    assert tool.parameter_schema["required"] == ["path"]
  end

  test "the configured default implements the provider boundary" do
    adapter = Kodo.LLM.adapter()

    assert Code.ensure_loaded?(adapter)
    assert function_exported?(adapter, :generate, 4)
  end

  test "rejects catalog models whose provider cannot be dispatched" do
    assert {:error, {:model_not_available, _reason}} =
             Adapter.validate_model(
               "302ai:MiniMax-M1",
               %{"reasoning" => "none"},
               Kodo.Agent.Roles.fetch!(:primary)
             )
  end

  test "uses every validated ReqLLM reasoning effort in request options" do
    contract = Kodo.Agent.Roles.fetch!(:primary)

    for reasoning <- ~w(xhigh max) do
      assert {:ok, _metadata} =
               Adapter.validate_model(
                 "anthropic:claude-fable-5",
                 %{"reasoning" => reasoning},
                 contract
               )

      assert Adapter.request_options([], timeout: 100, reasoning: reasoning)[:reasoning_effort] ==
               String.to_existing_atom(reasoning)
    end
  end

  test "rejects reasoning values the adapter cannot encode" do
    assert {:error, {:unsupported_reasoning, "extreme"}} =
             Adapter.validate_model(
               "anthropic:claude-fable-5",
               %{"reasoning" => "extreme"},
               Kodo.Agent.Roles.fetch!(:primary)
             )
  end

  test "reconstructs a tool exchange from provider-independent persisted values" do
    context =
      Adapter.build_context([
        %{"role" => "system", "content" => "system"},
        %{"role" => "user", "content" => "inspect"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call-1",
              "name" => "read_file",
              "arguments" => %{"path" => "mix.exs"}
            }
          ]
        },
        %{
          "role" => "tool",
          "tool_call_id" => "call-1",
          "name" => "read_file",
          "content" => %{"content" => "project", "truncated" => false}
        }
      ])

    assert [system, user, assistant, result] = context.messages
    assert system.role == :system
    assert user.role == :user
    assert [%{id: "call-1"}] = assistant.tool_calls
    assert result.role == :tool
    assert result.tool_call_id == "call-1"
    assert result.name == "read_file"
  end

  test "reconstructs reasoning continuity and provider tool metadata" do
    tool_call =
      "call-1"
      |> ReqLLM.ToolCall.new("read_file", ~s({"path":"mix.exs"}))
      |> ReqLLM.ToolCall.put_metadata(%{thought_signature: "signed-call"})

    message = %ReqLLM.Message{
      role: :assistant,
      content: [
        ReqLLM.Message.ContentPart.thinking("checking"),
        ReqLLM.Message.ContentPart.text("answer", %{index: 1})
      ],
      metadata: %{
        response_id: "response-1",
        phase: "final_answer",
        phase_items: [%{"phase" => "final_answer", "content" => []}]
      },
      reasoning_details: [
        %ReqLLM.Message.ReasoningDetails{
          text: nil,
          signature: "encrypted-reasoning",
          encrypted?: true,
          provider: :google,
          format: "thought_signature",
          index: 0,
          provider_data: %{"opaque" => "value"}
        }
      ],
      tool_calls: [tool_call]
    }

    provider_state =
      message
      |> Adapter.dump_assistant("answer", [tool_call])
      |> Jason.encode!()
      |> Jason.decode!()

    context =
      Adapter.build_context([
        %{"role" => "assistant", "provider_state" => provider_state}
      ])

    assert [assistant] = context.messages
    assert assistant.content == message.content
    assert assistant.metadata == message.metadata

    assert [%{signature: "encrypted-reasoning", provider: :google}] =
             assistant.reasoning_details

    assert [restored_tool_call] = assistant.tool_calls
    assert restored_tool_call == tool_call
  end
end
