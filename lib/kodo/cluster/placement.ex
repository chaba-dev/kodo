defmodule Kodo.Cluster.Placement do
  @moduledoc """
  Selects a compatible control-plane instance for a session coordinator.

  Placement is an advisory, decentralized decision over durable instance metadata. The selected
  coordinator must still claim the session through PostgreSQL ownership fencing before it can
  advance state or dispatch effects.
  """

  import Ecto.Query

  alias Kodo.Cluster.Instance
  alias Kodo.Cluster.Instances
  alias Kodo.Repo
  alias Kodo.Sessions.Session

  @required_capabilities ["session-events-v1", "session-ownership-v1"]
  @capacity_statuses ["idle", "running", "awaiting_approval"]

  @doc "Returns a reachable, compatible instance and its distributed Erlang node."
  def select(session_id, stale_after_seconds)
      when is_integer(stale_after_seconds) and stale_after_seconds >= 0 do
    reachable_nodes = Map.new([node() | Node.list()], &{Atom.to_string(&1), &1})

    owner_boot_id =
      Repo.one(
        from(session in Session, where: session.id == ^session_id, select: session.owner_boot_id)
      )

    candidates =
      stale_after_seconds
      |> Instances.list_eligible()
      |> Enum.filter(&(compatible?(&1) and Map.has_key?(reachable_nodes, &1.node_name)))
      |> with_load()

    case choose(candidates, owner_boot_id, session_id) do
      nil -> {:error, :no_compatible_instance}
      {instance, _load} -> {:ok, instance, Map.fetch!(reachable_nodes, instance.node_name)}
    end
  end

  defp compatible?(%Instance{protocol_capabilities: capabilities}) do
    Enum.all?(@required_capabilities, &(&1 in capabilities))
  end

  defp with_load([]), do: []

  defp with_load(instances) do
    boot_ids = Enum.map(instances, & &1.boot_id)

    loads =
      Session
      |> where(
        [session],
        session.owner_boot_id in ^boot_ids and session.status in ^@capacity_statuses
      )
      |> group_by([session], session.owner_boot_id)
      |> select([session], {session.owner_boot_id, count(session.id)})
      |> Repo.all()
      |> Map.new()

    Enum.map(instances, &{&1, Map.get(loads, &1.boot_id, 0)})
  end

  defp choose(candidates, owner_boot_id, session_id) do
    Enum.find(candidates, fn {instance, _load} -> instance.boot_id == owner_boot_id end) ||
      candidates
      |> Enum.reject(fn {instance, load} -> load >= instance.capacity end)
      |> Enum.min(&preferred?(&1, &2, session_id), fn -> nil end)
  end

  defp preferred?({left, left_load}, {right, right_load}, session_id) do
    left_weight = left_load * right.capacity
    right_weight = right_load * left.capacity

    if left_weight == right_weight do
      placement_key(session_id, left.boot_id) <= placement_key(session_id, right.boot_id)
    else
      left_weight < right_weight
    end
  end

  defp placement_key(session_id, boot_id) do
    :crypto.hash(:sha256, session_id <> boot_id)
  end
end
