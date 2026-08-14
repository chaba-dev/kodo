defmodule Kodo.Cluster.DiscoveryMonitor do
  @moduledoc "Publishes immediate BEAM process and node membership changes as scheduling hints."

  use GenServer

  alias Kodo.Cluster.Discovery

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    {ref, groups} = :pg.monitor_scope(Discovery.scope())
    :ok = :net_kernel.monitor_nodes(true, node_type: :all)

    {:ok, %{monitor_ref: ref, groups: Map.new(groups)}}
  end

  @impl true
  def handle_info({ref, action, group, pids}, %{monitor_ref: ref} = state)
      when action in [:join, :leave] do
    groups = update_members(state.groups, action, group, pids)

    case Discovery.parse_group(group) do
      {:ok, kind, id} ->
        broadcast({:cluster_membership, action, kind, id, pids, Map.get(groups, group, [])})

      :error ->
        :ok
    end

    {:noreply, %{state | groups: groups}}
  end

  def handle_info({:nodeup, node, info}, state) do
    broadcast({:cluster_node, :up, node, info})
    {:noreply, state}
  end

  def handle_info({:nodedown, node, info}, state) do
    broadcast({:cluster_node, :down, node, info})
    {:noreply, state}
  end

  def handle_info({:nodeup, node}, state) do
    broadcast({:cluster_node, :up, node, []})
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    broadcast({:cluster_node, :down, node, []})
    {:noreply, state}
  end

  defp update_members(groups, :join, group, pids) do
    Map.update(groups, group, pids, fn members -> Enum.uniq(pids ++ members) end)
  end

  defp update_members(groups, :leave, group, pids) do
    remaining = Enum.reject(Map.get(groups, group, []), &(&1 in pids))

    if remaining == [], do: Map.delete(groups, group), else: Map.put(groups, group, remaining)
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Kodo.PubSub, Discovery.topic(), message)
  end
end
