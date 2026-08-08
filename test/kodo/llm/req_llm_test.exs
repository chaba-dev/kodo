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
    assert function_exported?(adapter, :continue, 5)
  end
end
