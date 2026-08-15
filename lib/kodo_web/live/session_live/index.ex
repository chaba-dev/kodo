defmodule KodoWeb.SessionLive.Index do
  use KodoWeb, :live_view

  alias Kodo.Cluster.Discovery
  alias Kodo.Runners
  alias Kodo.Sessions

  @impl true
  def mount(_params, _session, socket) do
    sessions = Sessions.list_sessions(socket.assigns.current_scope)

    sessions = subscribe_and_refresh(socket, sessions)

    {:ok,
     socket
     |> assign(:page_title, "Sessions")
     |> stream(:sessions, sessions)}
  end

  defp subscribe_and_refresh(socket, sessions) do
    if connected?(socket) do
      :ok = Discovery.subscribe()
      :ok = Sessions.subscribe_index()
      Sessions.list_sessions(socket.assigns.current_scope)
    else
      sessions
    end
  end

  @impl true
  def handle_info(:session_index_changed, socket), do: {:noreply, refresh(socket)}

  def handle_info({:cluster_membership, _action, :runner, _id, _changed, _remaining}, socket),
    do: {:noreply, refresh(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh(socket) do
    stream(socket, :sessions, Sessions.list_sessions(socket.assigns.current_scope), reset: true)
  end

  defp repository_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp repository_name(%{workspace_root: root}), do: Path.basename(root)

  defp status_tone("running"), do: "bg-sky-400"
  defp status_tone("awaiting_approval"), do: "bg-amber-400"
  defp status_tone("completed"), do: "bg-emerald-400"
  defp status_tone("failed"), do: "bg-rose-400"
  defp status_tone("cancelled"), do: "bg-zinc-400"
  defp status_tone(_status), do: "bg-violet-400"
end
