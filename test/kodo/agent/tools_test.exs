defmodule Kodo.Agent.ToolsTest do
  use ExUnit.Case, async: true

  alias Kodo.Agent.Tools

  test "translates only exact typed runner arguments" do
    assert {:ok, %{"tool" => "apply_patch", "patch" => "patch"}} =
             Tools.request("apply_patch", %{"patch" => "patch"})

    assert {:error, :invalid_tool_call} = Tools.request("apply_patch", %{})

    assert {:error, :invalid_tool_call} =
             Tools.request("apply_patch", %{"patch" => "patch", "extra" => true})

    assert {:error, :invalid_tool_call} =
             Tools.request("poll_command", %{
               "process_id" => "not-a-uuid",
               "after_sequence" => 0
             })

    assert {:error, :invalid_tool_call} =
             Tools.request("read_file", %{"path" => "file", "offset" => 0, "limit" => "10"})
  end
end
