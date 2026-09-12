defmodule Kodo.Agent.ExecutionRouteChange do
  @moduledoc "Validates atomic execution-route changes against approved compatibility records."

  alias Kodo.Agent.ModelMapping

  @routes ~w(openai openai_codex)
  @approved_records []

  @doc "Returns records backed by successful exact-identity compatibility evidence."
  def approved_records, do: @approved_records

  def change(mapping, destination, records \\ @approved_records)

  def change(mapping, destination, records) when destination in @routes and is_list(records) do
    with {:ok, mapping} <- change_mapping(mapping),
         affected = affected_roles(mapping, destination),
         false <- affected == [],
         [] <- incompatible_roles(affected, destination, records) do
      {:ok, apply_route(mapping, affected, destination)}
    else
      {:error, _reason} = error -> error
      true -> {:error, :execution_route_unchanged}
      roles when is_list(roles) -> {:error, {:incompatible_execution_route, roles}}
    end
  end

  def change(_mapping, _destination, _records), do: {:error, :unsupported_execution_route}

  defp change_mapping(mapping) do
    case ModelMapping.validate_snapshot(mapping) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, :invalid_model_mapping_snapshot} ->
        if explicit_snapshot?(mapping),
          do: {:error, :invalid_model_mapping_snapshot},
          else: {:ok, ModelMapping.snapshot(mapping)}
    end
  end

  defp explicit_snapshot?(%{"roles" => roles}) when is_map(roles) do
    Enum.any?(roles, fn {_role, mapping} ->
      is_map(mapping) and is_map_key(mapping, "capability_contract")
    end)
  end

  defp explicit_snapshot?(_mapping), do: false

  defp affected_roles(mapping, destination) do
    Enum.filter(mapping["roles"], fn {_role, role_mapping} ->
      role_mapping["execution_route"] in @routes and
        role_mapping["execution_route"] != destination
    end)
  end

  defp incompatible_roles(affected, destination, records) do
    for {role, role_mapping} <- affected,
        not compatible?(role, role_mapping, destination, records),
        do: role
  end

  defp compatible?(role, role_mapping, destination, records) do
    Enum.any?(records, fn record ->
      record.role == role and
        record.source == role_mapping["execution_route"] and
        record.destination == destination and
        record.selector == role_mapping["model_selector"] and
        record.role_contract == role_mapping["role_contract"] and
        record.reasoning == role_mapping["reasoning"] and
        record.capability_contract == role_mapping["capability_contract"] and
        record.status == :approved
    end)
  end

  defp apply_route(mapping, affected, destination) do
    affected_roles = MapSet.new(affected, &elem(&1, 0))

    roles =
      Map.new(mapping["roles"], fn {role, role_mapping} ->
        if MapSet.member?(affected_roles, role) do
          selector = role_mapping["model_selector"]

          {role,
           role_mapping
           |> Map.put("provider", destination)
           |> Map.put("execution_route", destination)
           |> Map.put("model", "#{destination}:#{selector}")
           |> put_in(["sources", "model"], "session_route_change")}
        else
          {role, role_mapping}
        end
      end)

    %{mapping | "roles" => roles}
  end
end
