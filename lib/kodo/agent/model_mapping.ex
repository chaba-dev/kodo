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

  defp provider(model), do: model |> String.split(~r/[:\/]/, parts: 2) |> hd()
end
