defmodule Kodo.Agent.ModelCapabilities do
  @moduledoc "Validates a resolved model against one role contract before provider use."

  alias ReqLLM.ModelHelpers

  def validate(model_spec, role_mapping, contract) do
    required = requirements(contract)

    with {:ok, model} <- resolve(model_spec),
         [] <- missing_capabilities(model, role_mapping, required) do
      {:ok, validation_metadata(model, required)}
    else
      {:error, reason} -> {:error, {:model_not_available, reason}}
      missing when is_list(missing) -> {:error, {:model_capabilities_missing, missing}}
    end
  end

  defp resolve(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} -> {:ok, model}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp missing_capabilities(model, role_mapping, required) do
    []
    |> require_capability(required.tools && !ModelHelpers.tools_enabled?(model), "tool_calling")
    |> require_structured_output(model, required.structured_output)
    |> require_capability(context_window(model) < required.min_context, "context_window")
    |> require_modalities(model, required.input_modalities)
    |> require_reasoning(model, role_mapping["reasoning"])
  end

  defp require_structured_output(missing, _model, false), do: missing

  defp require_structured_output(missing, model, :json_schema) do
    require_capability(missing, !ModelHelpers.json_schema?(model), "json_schema")
  end

  defp require_structured_output(missing, model, :object) do
    require_capability(missing, !object_output?(model), "structured_output")
  end

  defp require_capability(missing, true, capability), do: [capability | missing]
  defp require_capability(missing, false, _capability), do: missing

  defp require_modalities(missing, model, required) do
    supported = model.modalities |> then(&(&1 && &1.input)) |> List.wrap()

    Enum.reduce(required, missing, fn modality, missing ->
      require_capability(missing, modality not in supported, "input:#{modality}")
    end)
  end

  defp require_reasoning(missing, _model, reasoning) when reasoning in [nil, "none"], do: missing

  defp require_reasoning(missing, model, reasoning) do
    effort = get_in(model.capabilities, [:reasoning, :effort])

    supported =
      ModelHelpers.reasoning_enabled?(model) and is_map(effort) and
        Map.get(effort, :supported) == true and
        reasoning in Enum.map(Map.get(effort, :values, []), &to_string/1)

    require_capability(missing, !supported, "reasoning:#{reasoning}")
  end

  defp validation_metadata(model, required) do
    %{
      "catalog_model" => model.id,
      "context_window" => context_window(model),
      "input_modalities" => Enum.map(model.modalities.input, &to_string/1),
      "json_schema" => ModelHelpers.json_schema?(model),
      "structured_output" => object_output?(model),
      "required_context_window" => required.min_context,
      "tools" => ModelHelpers.tools_enabled?(model)
    }
  end

  defp object_output?(model), do: get_in(model.execution, [:object, :supported]) == true

  defp context_window(model), do: (model.limits && model.limits.context) || 0

  defp requirements(contract) do
    Map.get(contract, :capabilities, %{
      tools: true,
      structured_output: false,
      min_context: 1,
      input_modalities: [:text]
    })
  end
end
