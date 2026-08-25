defmodule Kodo.Agent.RolesTest do
  use ExUnit.Case, async: true

  alias Kodo.Agent.Roles

  test "defines complete alpha contracts for every role" do
    assert Map.keys(Roles.all()) |> Enum.sort() == [:primary, :review, :search]

    for {_role, contract} <- Roles.all() do
      assert contract.id == "alpha-v1"
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

  test "resolves only the active prerelease contract" do
    assert Roles.fetch!(:primary, "alpha-v1") == Roles.fetch!(:primary)
    assert Roles.fetch!(:primary).prompt =~ "exact public verification command"
    assert Roles.fetch!(:search).prompt =~ "reserve the final turn"
    assert Roles.fetch!(:review).prompt =~ "original task is authoritative"
    assert Roles.fetch!(:review).capabilities.structured_output == :object

    assert_raise KeyError, fn -> Roles.fetch!(:review, "beta-v1") end
  end
end
