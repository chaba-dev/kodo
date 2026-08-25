defmodule Kodo.Agent.ModelCapabilitiesTest do
  use ExUnit.Case, async: true

  alias Kodo.Agent.ModelCapabilities
  alias Kodo.Agent.Roles

  test "accepts the balanced model for every current role contract" do
    for {role, contract} <- Roles.all() do
      mapping = %{"reasoning" => "none"}

      assert {:ok, metadata} =
               ModelCapabilities.validate("openai:gpt-4o-mini", mapping, contract),
             "expected balanced model to support #{role}"

      assert metadata["tools"]
      assert metadata["context_window"] >= contract.capabilities.min_context
      assert "text" in metadata["input_modalities"]
    end
  end

  test "accepts strict structured-output fallback for GPT-5.6 review models" do
    for model <- ~w(openai:gpt-5.6-terra openai:gpt-5.6-sol) do
      assert {:ok, metadata} =
               ModelCapabilities.validate(
                 model,
                 %{"reasoning" => "none"},
                 Roles.fetch!(:review)
               )

      refute metadata["json_schema"]
      assert metadata["structured_output"]
    end
  end

  test "can require native JSON Schema explicitly" do
    contract =
      Roles.fetch!(:review)
      |> put_in([:capabilities, :structured_output], :json_schema)

    assert {:error, {:model_capabilities_missing, ["json_schema"]}} =
             ModelCapabilities.validate(
               "openai:gpt-5.6-terra",
               %{"reasoning" => "none"},
               contract
             )
  end

  test "reports every missing role capability" do
    model = %LLMDB.Model{
      id: "limited",
      provider: :openai,
      capabilities: %{tools: %{enabled: false}, json: %{schema: false}},
      limits: %{context: 8_000},
      modalities: %{input: [:text], output: [:text]}
    }

    assert {:error, {:model_capabilities_missing, missing}} =
             ModelCapabilities.validate(model, %{"reasoning" => "none"}, Roles.fetch!(:review))

    assert Enum.sort(missing) == ["context_window", "structured_output", "tool_calling"]
  end

  test "requires configured reasoning effort support" do
    model = %LLMDB.Model{
      id: "no-reasoning",
      provider: :openai,
      capabilities: %{tools: %{enabled: true}, reasoning: %{enabled: false}},
      limits: %{context: 128_000},
      modalities: %{input: [:text], output: [:text]}
    }

    assert {:error, {:model_capabilities_missing, ["reasoning:high"]}} =
             ModelCapabilities.validate(model, %{"reasoning" => "high"}, Roles.fetch!(:primary))
  end

  test "rejects an unknown model before provider dispatch" do
    assert {:error, {:model_not_available, _reason}} =
             ModelCapabilities.validate(
               "missing-provider:missing-model",
               %{"reasoning" => "none"},
               Roles.fetch!(:primary)
             )
  end
end
