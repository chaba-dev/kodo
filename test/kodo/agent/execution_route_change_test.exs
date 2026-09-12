defmodule Kodo.Agent.ExecutionRouteChangeTest do
  use ExUnit.Case, async: true

  alias Kodo.Agent.ExecutionRouteChange
  alias Kodo.Agent.ModelMapping

  test "rejects the live-tested gpt-5.4 route pair without an approved identity record" do
    mapping = mapping_for_selector("gpt-5.4")

    assert {:error, {:incompatible_execution_route, ["primary", "review", "search"]}} =
             ExecutionRouteChange.change(mapping, "openai_codex")

    assert ModelMapping.role!(mapping, :primary)["provider"] == "openai"
  end

  test "changes every affected role atomically when all exact selectors are approved" do
    mapping = mapping_for_selector("gpt-4o-mini")
    records = records_for(mapping, "openai_codex")

    assert {:ok, changed} =
             ExecutionRouteChange.change(mapping, "openai_codex", records)

    for role <- [:primary, :search, :review] do
      role_mapping = ModelMapping.role!(changed, role)
      assert role_mapping["model"] == "openai_codex:gpt-4o-mini"
      assert role_mapping["model_selector"] == "gpt-4o-mini"
      assert role_mapping["execution_route"] == "openai_codex"
      assert role_mapping["role_contract"] == "alpha-v1"
    end
  end

  test "rejects the whole role set when one role has no approved record" do
    mapping = mapping_for_selector("gpt-4o-mini")
    records = records_for(mapping, "openai_codex") |> tl()

    assert {:error, {:incompatible_execution_route, [missing_role]}} =
             ExecutionRouteChange.change(mapping, "openai_codex", records)

    assert missing_role in ~w(primary review search)
    assert ModelMapping.role!(mapping, :primary)["provider"] == "openai"
  end

  test "rejects evidence for a different reasoning or capability envelope" do
    mapping = mapping_for_selector("gpt-4o-mini")
    records = records_for(mapping, "openai_codex")

    reasoning_mismatch =
      Enum.map(records, &Map.put(&1, :reasoning, "medium"))

    assert {:error, {:incompatible_execution_route, ["primary", "review", "search"]}} =
             ExecutionRouteChange.change(mapping, "openai_codex", reasoning_mismatch)

    capability_mismatch =
      Enum.map(records, fn record ->
        put_in(record, [:capability_contract, "requirements", "tools"], false)
      end)

    assert {:error, {:incompatible_execution_route, ["primary", "review", "search"]}} =
             ExecutionRouteChange.change(mapping, "openai_codex", capability_mismatch)
  end

  test "preserves and verifies an explicit mapping capability envelope" do
    mapping = mapping_for_selector("gpt-4o-mini") |> ModelMapping.snapshot()
    records = records_for(mapping, "openai_codex")

    changed_requirement =
      put_in(
        mapping,
        ["roles", "primary", "capability_contract", "requirements", "min_context"],
        200_000
      )

    assert {:error, {:incompatible_execution_route, ["primary"]}} =
             ExecutionRouteChange.change(changed_requirement, "openai_codex", records)
  end

  defp mapping_for_selector(selector) do
    ModelMapping.balanced([
      {"test",
       %{
         primary: %{model: "openai:#{selector}"},
         search: %{model: "openai:#{selector}"},
         review: %{model: "openai:#{selector}"}
       }}
    ])
  end

  defp records_for(mapping, destination) do
    mapping
    |> ModelMapping.snapshot()
    |> Map.fetch!("roles")
    |> Enum.map(fn {role, role_mapping} ->
      %{
        role: role,
        source: "openai",
        destination: destination,
        selector: role_mapping["model"] |> String.split(":", parts: 2) |> List.last(),
        role_contract: role_mapping["role_contract"],
        reasoning: role_mapping["reasoning"],
        capability_contract: role_mapping["capability_contract"],
        status: :approved
      }
    end)
  end
end
