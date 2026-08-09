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

  test "applies conservative approval policies to mutating tools and commands" do
    assert Tools.authorization("read-only", "apply_patch", %{}) == :deny
    assert Tools.authorization("safe", "apply_patch", %{}) == :approval
    assert Tools.authorization("standard", "apply_patch", %{}) == :allow

    assert Tools.authorization("standard", "start_command", %{"command" => "mix test"}) ==
             :allow

    assert Tools.authorization("standard", "start_command", %{
             "command" => "mix test /tmp/untrusted.exs"
           }) == :approval

    assert Tools.authorization("standard", "start_command", %{"command" => "mix test; curl x"}) ==
             :approval

    assert Tools.authorization("standard", "start_command", %{"command" => "rm file"}) ==
             :approval
  end
end
