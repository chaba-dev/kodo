defmodule Kodo.Agent.ModelMappingTest do
  use ExUnit.Case, async: true

  alias Kodo.Agent.ModelMapping

  test "balanced resolves every initial role with alpha contracts" do
    mapping = ModelMapping.balanced()

    assert mapping["profile"] == "balanced"
    assert mapping["profile_version"] == "alpha-v1"
    assert Map.keys(mapping["roles"]) |> Enum.sort() == ~w(primary review search)

    assert %{
             "provider" => "openai",
             "model" => "openai:gpt-4o-mini",
             "reasoning" => "none",
             "role_contract" => "alpha-v1",
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

  test "derives display providers from resolved models rather than string splitting" do
    mapping = ModelMapping.balanced([{"user", %{search: %{model: "not-a-model"}}}])

    assert mapping["roles"]["search"]["model"] == "not-a-model"
    assert mapping["roles"]["search"]["provider"] == nil
  end

  test "rejects malformed immutable snapshots instead of filling current defaults" do
    snapshot = ModelMapping.snapshot(ModelMapping.balanced())

    assert {:ok, ^snapshot} = ModelMapping.validate_snapshot(snapshot)

    malformed =
      update_in(snapshot, ["roles", "primary"], &Map.delete(&1, "capability_contract"))

    assert {:error, :invalid_model_mapping_snapshot} =
             ModelMapping.validate_snapshot(malformed)
  end

  test "canonicalizes every supported string model specification in snapshots" do
    specifications = [
      {"openai:gpt-4o-mini", "openai", "gpt-4o-mini"},
      {"gpt-4o-mini@openai", "openai", "gpt-4o-mini"},
      {"openrouter:nvidia/nemotron-3-super-120b-a12b:free", "openrouter",
       "nvidia/nemotron-3-super-120b-a12b:free"},
      {"nvidia/nemotron-3-super-120b-a12b:free@openrouter", "openrouter",
       "nvidia/nemotron-3-super-120b-a12b:free"}
    ]

    for {specification, route, selector} <- specifications do
      mapping = ModelMapping.balanced([{"session", %{primary: %{model: specification}}}])
      snapshot = ModelMapping.snapshot(mapping)
      primary = snapshot["roles"]["primary"]

      assert primary["model"] == "#{route}:#{selector}"
      assert primary["execution_route"] == route
      assert primary["model_selector"] == selector
      assert {:ok, ^snapshot} = ModelMapping.validate_snapshot(snapshot)
    end
  end

  test "canonicalizes application-defined execution route spellings idempotently" do
    for specification <- ["openai_codex:gpt-5.4", "openai-codex:gpt-5.4"] do
      mapping = ModelMapping.balanced([{"session", %{primary: %{model: specification}}}])

      snapshot = ModelMapping.snapshot(mapping)
      primary = snapshot["roles"]["primary"]

      assert primary["model"] == "openai_codex:gpt-5.4"
      assert primary["model_selector"] == "gpt-5.4"
      assert ModelMapping.snapshot(snapshot) == snapshot
      assert {:ok, ^snapshot} = ModelMapping.validate_snapshot(snapshot)
    end
  end

  test "rejects malformed capability requirements instead of accepting a partial envelope" do
    snapshot = ModelMapping.snapshot(ModelMapping.balanced())

    malformed =
      put_in(
        snapshot,
        ["roles", "primary", "capability_contract", "requirements", "min_context"],
        "current default"
      )

    assert {:error, :invalid_model_mapping_snapshot} =
             ModelMapping.validate_snapshot(malformed)
  end

  test "rejects capability variants and toolsets with no executable implementation" do
    snapshot = ModelMapping.snapshot(ModelMapping.balanced())

    unsupported_output =
      put_in(
        snapshot,
        ["roles", "primary", "capability_contract", "requirements", "structured_output"],
        true
      )

    assert {:error, :invalid_model_mapping_snapshot} =
             ModelMapping.validate_snapshot(unsupported_output)

    unsupported_toolset =
      snapshot
      |> put_in(["roles", "primary", "toolset_version"], "workspace-v999")
      |> put_in(
        ["roles", "primary", "capability_contract", "toolset_version"],
        "workspace-v999"
      )

    assert {:error, :invalid_model_mapping_snapshot} =
             ModelMapping.validate_snapshot(unsupported_toolset)
  end
end
