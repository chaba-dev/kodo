defmodule Kodo.Agent.ModelMapping do
  @moduledoc "Resolves versioned model profiles and role-specific override layers."

  alias Kodo.Agent.Roles

  @profile "balanced"
  @profile_version "alpha-v1"
  @balanced %{
    primary: %{model: "openai:gpt-4o-mini", reasoning: "none"},
    search: %{model: "openai:gpt-4o-mini", reasoning: "none"},
    review: %{model: "openai:gpt-4o-mini", reasoning: "none"}
  }

  @type override_layer :: {String.t(), %{optional(Roles.role()) => map()}}

  @spec balanced([override_layer()]) :: map()
  def balanced(layers \\ []) do
    roles =
      Enum.into(@balanced, %{}, fn {role, recommendation} ->
        resolved =
          Enum.reduce(
            layers,
            with_profile_sources(recommendation),
            fn {source, overrides}, role_mapping ->
              apply_override(role_mapping, source, Map.get(overrides, role, %{}))
            end
          )

        contract = Roles.fetch!(role)

        {Atom.to_string(role),
         Map.merge(resolved, %{
           "role_contract" => contract.id,
           "toolset_version" => contract.toolset_version
         })}
      end)

    %{
      "profile" => @profile,
      "profile_version" => @profile_version,
      "roles" => roles
    }
  end

  @doc "Upgrades persisted pre-alpha mappings while preserving their model choices."
  @spec normalize(map()) :: map()
  def normalize(%{"profile_version" => @profile_version} = mapping), do: mapping

  def normalize(%{"roles" => persisted_roles}) when is_map(persisted_roles) do
    current = balanced()

    roles =
      Map.new(current["roles"], fn {role, current_role} ->
        persisted_role = Map.get(persisted_roles, role, %{})
        {role, normalize_role(current_role, persisted_role)}
      end)

    %{current | "roles" => roles}
  end

  def normalize(_mapping), do: balanced()

  @doc "Freezes explicit route and selector identity into every role for durable turn replay."
  def snapshot(mapping) do
    mapping = normalize(mapping)

    roles =
      Map.new(mapping["roles"], fn {role, role_mapping} ->
        contract = Roles.fetch!(role_atom(role), role_mapping["role_contract"])

        {role,
         role_mapping
         |> Map.put("execution_route", role_mapping["provider"])
         |> Map.put("model_selector", model_selector(role_mapping["model"]))
         |> Map.put("capability_contract", capability_contract(contract))}
      end)

    %{mapping | "roles" => roles}
  end

  defp capability_contract(contract) do
    %{
      "id" => contract.id,
      "toolset_version" => contract.toolset_version,
      "requirements" => %{
        "tools" => contract.capabilities.tools,
        "structured_output" => stringify(contract.capabilities.structured_output),
        "min_context" => contract.capabilities.min_context,
        "input_modalities" => Enum.map(contract.capabilities.input_modalities, &to_string/1)
      }
    }
  end

  defp role_atom("primary"), do: :primary
  defp role_atom("search"), do: :search
  defp role_atom("review"), do: :review

  defp stringify(value) when is_boolean(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp normalize_role(current, persisted) do
    normalized =
      Enum.reduce(["model", "reasoning"], current, fn field, mapping ->
        case Map.get(persisted, field) do
          value when is_binary(value) and value != "" ->
            source = get_in(persisted, ["sources", field]) || "persisted"

            mapping
            |> Map.put(field, value)
            |> put_in(["sources", field], source)

          _other ->
            mapping
        end
      end)

    Map.put(normalized, "provider", provider(normalized["model"]))
  end

  @spec role!(map(), Roles.role()) :: map()
  def role!(mapping, role) do
    case get_in(mapping, ["roles", Atom.to_string(role)]) do
      nil -> raise KeyError, key: role, term: mapping
      role_mapping -> role_mapping
    end
  end

  defp with_profile_sources(recommendation) do
    %{
      "provider" => provider(recommendation.model),
      "model" => recommendation.model,
      "reasoning" => recommendation.reasoning,
      "sources" => %{"model" => "profile", "reasoning" => "profile"}
    }
  end

  defp apply_override(mapping, source, override) do
    Enum.reduce([:model, :reasoning], mapping, fn field, resolved ->
      case Map.fetch(override, field) do
        {:ok, value} when is_binary(value) and value != "" ->
          key = Atom.to_string(field)

          resolved
          |> Map.put(key, value)
          |> maybe_update_provider(field, value)
          |> put_in(["sources", key], source)

        _other ->
          resolved
      end
    end)
  end

  defp maybe_update_provider(mapping, :model, model),
    do: Map.put(mapping, "provider", provider(model))

  defp maybe_update_provider(mapping, :reasoning, _reasoning), do: mapping

  defp provider(model) do
    case ReqLLM.model(model) do
      {:ok, %LLMDB.Model{provider: provider}} -> Atom.to_string(provider)
      {:error, _reason} -> nil
    end
  end

  defp model_selector(model) do
    case String.split(model, ":", parts: 2) do
      [_provider, selector] -> selector
      [selector] -> selector
    end
  end
end
