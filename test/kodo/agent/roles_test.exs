defmodule Kodo.Agent.RolesTest do
  use ExUnit.Case, async: true

  alias Kodo.Agent.Roles

  test "defines complete versioned contracts for the initial roles" do
    assert Map.keys(Roles.all()) |> Enum.sort() == [:primary, :review, :search]

    for {role, contract} <- Roles.all() do
      assert contract.version == %{primary: 6, review: 5, search: 3}[role]
      assert is_atom(contract.responsibility)
      assert is_binary(contract.prompt)
      assert contract.prompt != ""
      assert contract.tools in [:workspace, :read_only]
      assert is_binary(contract.toolset_version)
      assert contract.capabilities.tools
      assert contract.capabilities.min_context > 0
      assert contract.capabilities.input_modalities == [:text]
      assert contract.budget.max_continuations > 0
      assert contract.budget.max_tokens > 0
      assert is_atom(contract.output)
    end
  end

  test "resolves a contract by its persisted version" do
    assert Roles.fetch!(:primary, 1).prompt ==
             "You are Kodo's primary coding agent. Inspect evidence, make the smallest correct patch, and verify it."

    refute Map.has_key?(Roles.fetch!(:primary, 1), :capabilities)
    assert Roles.fetch!(:primary, 2).capabilities.min_context == 100_000
    assert Roles.fetch!(:primary, 3).toolset_version == "workspace-v2"
    assert Roles.fetch!(:primary, 4).toolset_version == "workspace-v3"
    assert Roles.fetch!(:primary, 4).prompt =~ "never send replacement text alone"
    assert Roles.fetch!(:primary, 5).toolset_version == "workspace-v4"
    assert Roles.fetch!(:primary, 5).prompt =~ "Prefer replace_text"
    assert Roles.fetch!(:primary, 6).toolset_version == "workspace-v5"
    assert Roles.fetch!(:primary, 6).prompt =~ "exact public verification command"
    assert Roles.fetch!(:primary, 6).prompt =~ "After every edit"
    assert Roles.fetch!(:search, 3).budget.max_continuations == 6
    assert Roles.fetch!(:search, 3).prompt =~ "reserve the final turn"
    assert Roles.fetch!(:review, 3).prompt =~ "actionable defect"
    assert Roles.fetch!(:review, 3).prompt =~ "Do not report a correct change"
    assert Roles.fetch!(:review, 3).prompt =~ "clean=true if and only if findings is empty"
    assert Roles.fetch!(:review, 4).prompt =~ "original task is authoritative"
    assert Roles.fetch!(:review, 4).prompt =~ "Never recommend reverting required behavior"
    assert Roles.fetch!(:review, 4).capabilities.structured_output == :json_schema
    assert Roles.fetch!(:review, 5).capabilities.structured_output == :object
  end
end
