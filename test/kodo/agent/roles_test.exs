defmodule Kodo.Agent.RolesTest do
  use ExUnit.Case, async: true

  alias Kodo.Agent.Roles

  test "defines complete versioned contracts for the initial roles" do
    assert Map.keys(Roles.all()) |> Enum.sort() == [:primary, :review, :search]

    for {_role, contract} <- Roles.all() do
      assert contract.version == 1
      assert is_atom(contract.responsibility)
      assert is_binary(contract.prompt)
      assert contract.prompt != ""
      assert contract.tools in [:workspace, :read_only]
      assert contract.budget.max_continuations > 0
      assert contract.budget.max_tokens > 0
      assert is_atom(contract.output)
    end
  end
end
