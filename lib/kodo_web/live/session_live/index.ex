defmodule KodoWeb.SessionLive.Index do
  use KodoWeb, :live_view

  alias Kodo.Cluster.Discovery
  alias Kodo.Sessions

  @impl true
  def mount(_params, _session, socket) do
    {sessions, cursor} = Sessions.list_sessions_page(socket.assigns.current_scope)
    {sessions, cursor} = subscribe_and_refresh(socket, sessions, cursor)

    {:ok,
     socket
     |> assign(:page_title, "Sessions")
     |> assign(:sessions_cursor, cursor)
     |> assign(:session_runner_ids, runner_ids(sessions))
     |> stream(:sessions, sessions)}
  end

  defp subscribe_and_refresh(socket, sessions, cursor) do
    if connected?(socket) do
      :ok = Discovery.subscribe()
      :ok = Sessions.subscribe_index(socket.assigns.current_scope)
      Sessions.list_sessions_page(socket.assigns.current_scope)
    else
      {sessions, cursor}
    end
  end

  @impl true
  def handle_event(
        "load_more_sessions",
        %{"before-updated-at" => updated_at, "before-id" => id},
        socket
      ) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, updated_at, _offset} ->
        {sessions, cursor} =
          Sessions.list_sessions_page(socket.assigns.current_scope,
            before: %{updated_at: updated_at, id: id}
          )

        {:noreply,
         socket
         |> assign(:sessions_cursor, cursor)
         |> update(:session_runner_ids, &MapSet.union(&1, runner_ids(sessions)))
         |> stream(:sessions, sessions, at: -1)}

      _invalid_cursor ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:session_index_changed, session_id}, socket) do
    {:noreply, refresh_session(socket, session_id)}
  end

  def handle_info(
        {:cluster_membership, _action, :runner, runner_id, _changed, _remaining},
        socket
      ) do
    if MapSet.member?(socket.assigns.session_runner_ids, runner_id),
      do: {:noreply, refresh_page(socket)},
      else: {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh_session(socket, session_id) do
    case Sessions.get_session_for_index(socket.assigns.current_scope, session_id) do
      nil ->
        socket

      session ->
        socket
        |> update(:session_runner_ids, &MapSet.put(&1, session.runner_id))
        |> stream_insert(:sessions, session, at: 0)
    end
  end

  defp refresh_page(socket) do
    {sessions, cursor} = Sessions.list_sessions_page(socket.assigns.current_scope)

    socket
    |> assign(:sessions_cursor, cursor)
    |> assign(:session_runner_ids, runner_ids(sessions))
    |> stream(:sessions, sessions, reset: true)
  end

  defp runner_ids(sessions), do: sessions |> Enum.map(& &1.runner_id) |> MapSet.new()
end
