defmodule Kodo.Agent.RolesTest do
  use ExUnit.Case, async: true

  alias Kodo.Agent.Roles

  test "defines complete versioned contracts for the initial roles" do
    assert Map.keys(Roles.all()) |> Enum.sort() == [:primary, :review, :search]

    for {role, contract} <- Roles.all() do
      assert contract.version == if(role == :primary, do: 3, else: 2)
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
  end
end
