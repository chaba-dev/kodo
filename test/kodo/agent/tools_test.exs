defmodule Kodo.Agent.ToolsTest do
  use ExUnit.Case, async: true

  alias Kodo.Agent.Tools

  test "resolves definitions by their persisted toolset version" do
    assert Tools.definitions("workspace-v1") == Tools.definitions()

    assert Enum.any?(Tools.definitions("workspace-v2"), &(&1.name == "delegate_search"))
    refute Enum.any?(Tools.definitions("read-only-v1"), &(&1.name == "delegate_search"))

    old_patch = Enum.find(Tools.definitions("workspace-v2"), &(&1.name == "apply_patch"))
    patch = Enum.find(Tools.definitions("workspace-v3"), &(&1.name == "apply_patch"))

    refute old_patch.description =~ "diff --git"
    assert patch.description =~ "diff --git"
    assert patch.description =~ "@@"

    replace = Enum.find(Tools.definitions("workspace-v4"), &(&1.name == "replace_text"))
    assert replace.description =~ "exactly once"

    assert Enum.any?(Tools.definitions("workspace-v5"), &(&1.name == "replace_text"))
    refute Enum.any?(Tools.definitions("workspace-v5"), &(&1.name == "apply_patch"))
  end

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

    assert {:ok,
            %{
              "tool" => "replace_text",
              "path" => "lib/example.ex",
              "old_text" => "before",
              "new_text" => "after"
            }} =
             Tools.request("replace_text", %{
               "path" => "lib/example.ex",
               "old_text" => "before",
               "new_text" => "after"
             })

    assert {:error, :invalid_tool_call} =
             Tools.request("replace_text", %{
               "path" => "lib/example.ex",
               "old_text" => "",
               "new_text" => "after"
             })
  end

  test "reserves the last model turn for an answer" do
    assert Tools.definitions_for_turn("workspace-v4", 1, 2) != []
    assert Tools.definitions_for_turn("workspace-v4", 2, 2) == []
    assert Tools.definitions_for_turn("read-only-v1", 6, 6) == []
  end

  test "applies conservative approval policies to mutating tools and commands" do
    assert Tools.authorization("read-only", "apply_patch", %{}) == :deny
    assert Tools.authorization("read-only", "replace_text", %{}) == :deny
    assert Tools.authorization("safe", "apply_patch", %{}) == :approval
    assert Tools.authorization("safe", "replace_text", %{}) == :approval
    assert Tools.authorization("standard", "apply_patch", %{}) == :allow
    assert Tools.authorization("standard", "replace_text", %{}) == :allow

    assert Tools.authorization("standard", "start_command", %{"command" => "mix test"}) ==
             :allow

    assert Tools.authorization("standard", "start_command", %{
             "command" => "mix test /tmp/untrusted.exs"
           }) == :approval

    assert Tools.authorization("standard", "start_command", %{"command" => "mix test; curl x"}) ==
             :approval

    assert Tools.authorization("standard", "start_command", %{"command" => "mix\ntest"}) ==
             :approval

    assert Tools.authorization("standard", "start_command", %{"command" => "mix\rtest"}) ==
             :approval

    assert Tools.authorization("standard", "start_command", %{"command" => "rm file"}) ==
             :approval
  end
end
