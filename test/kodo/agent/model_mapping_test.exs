defmodule Kodo.Agent.ModelMappingTest do
  use ExUnit.Case, async: true

  alias Kodo.Agent.ModelMapping

  test "balanced resolves every initial role with versioned contracts" do
    mapping = ModelMapping.balanced()

    assert mapping["profile"] == "balanced"
    assert mapping["profile_revision"] == 3
    assert Map.keys(mapping["roles"]) |> Enum.sort() == ~w(primary review search)

    assert %{
             "provider" => "openai",
             "model" => "openai:gpt-4o-mini",
             "reasoning" => "none",
             "role_contract_version" => 3,
             "sources" => %{"model" => "profile", "reasoning" => "profile"}
           } = mapping["roles"]["primary"]
  end

  test "a role override inherits every other recommendation" do
    mapping =
      ModelMapping.balanced([
        {"user", %{search: %{model: "ollama:qwen-coder", reasoning: "low"}}}
      ])

    assert mapping["roles"]["search"]["model"] == "ollama:qwen-coder"
    assert mapping["roles"]["search"]["provider"] == "ollama"
    assert mapping["roles"]["search"]["reasoning"] == "low"

    assert mapping["roles"]["search"]["sources"] == %{
             "model" => "user",
             "reasoning" => "user"
           }

    assert mapping["roles"]["primary"]["sources"]["model"] == "profile"
    assert mapping["roles"]["review"]["sources"]["model"] == "profile"
  end

  test "later layers override only the fields they specify" do
    mapping =
      ModelMapping.balanced([
        {"user", %{search: %{model: "user:model", reasoning: "low"}}},
        {"repository", %{search: %{model: "repository:model"}}},
        {"session", %{search: %{reasoning: "high"}}}
      ])

    search = mapping["roles"]["search"]
    assert search["model"] == "repository:model"
    assert search["reasoning"] == "high"
    assert search["sources"] == %{"model" => "repository", "reasoning" => "session"}
  end
end
