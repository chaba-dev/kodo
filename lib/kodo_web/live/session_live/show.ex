defmodule KodoWeb.SessionLive.Show do
  use KodoWeb, :live_view

  alias Kodo.Cluster.Discovery
  alias Kodo.Runners
  alias Kodo.Sessions
  alias Kodo.Sessions.Projection

  @message_types ["user_message", "assistant_message_completed"]
  @tool_types ["tool_requested", "tool_started", "tool_completed", "tool_failed"]
  @timeline_page_size 50

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Sessions.get_session(socket.assigns.current_scope, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Session not found")
         |> push_navigate(to: ~p"/sessions")}

      session ->
        mount_session(socket, session)
    end
  end

  defp mount_session(socket, session) do
    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")
      :ok = Discovery.subscribe()
      :ok = Sessions.subscribe_index(socket.assigns.current_scope)
    end

    timeline_page = Sessions.timeline_page(socket.assigns.current_scope, session.id)
    pending_approval = pending_approval(socket.assigns.current_scope, session)

    projection =
      Projection.from_session(
        session,
        Sessions.latest_event_sequence(socket.assigns.current_scope, session.id),
        timeline_page.tool_calls
      )
      |> Map.put(
        :pending_approval_id,
        pending_approval && pending_approval["approval_id"]
      )

    {sessions, sessions_cursor} = Sessions.list_sessions_page(socket.assigns.current_scope)
    sessions = include_selected_session(sessions, socket.assigns.current_scope, session.id)

    socket =
      socket
      |> stream_configure(:timeline, dom_id: & &1.id)
      |> assign(:page_title, session.title)
      |> assign(:session, session)
      |> assign(:runner, Runners.get_runner(session.runner_id))
      |> assign(:runner_online?, Runners.online?(session.runner_id))
      |> assign(:projection, projection)
      |> assign(:pending_approval, pending_approval)
      |> assign(:diff, latest_diff(socket.assigns.current_scope, session.id))
      |> assign(:timeline_cursor, timeline_page.before_sequence)
      |> assign(:message_form, to_form(%{"content" => ""}, as: :message))
      |> assign(:sessions_cursor, sessions_cursor)
      |> assign(:session_runner_ids, runner_ids(sessions))
      |> stream(:sessions, sessions)
      |> stream(:timeline, timeline_items(timeline_page.events, projection))

    {:ok, socket}
  end

  @impl true
  def handle_event("send_message", %{"message" => %{"content" => content}}, socket) do
    content = String.trim(content)

    case content do
      "" ->
        {:noreply, put_flash(socket, :error, "Message cannot be empty")}

      content ->
        case Sessions.start_turn(
               socket.assigns.current_scope,
               socket.assigns.session.id,
               content,
               Ecto.UUID.generate()
             ) do
          :ok ->
            {:noreply, assign(socket, :message_form, to_form(%{"content" => ""}, as: :message))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, control_error(reason))}
        end
    end
  end

  def handle_event("cancel", _params, socket) do
    case Sessions.cancel(socket.assigns.current_scope, socket.assigns.session.id) do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, control_error(reason))}
    end
  end

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

  def handle_event("load_older_timeline", %{"before-sequence" => sequence}, socket) do
    case Integer.parse(sequence) do
      {sequence, ""} ->
        page =
          Sessions.timeline_page(socket.assigns.current_scope, socket.assigns.session.id,
            before_sequence: sequence
          )

        projection = %{
          socket.assigns.projection
          | tool_calls: Map.merge(socket.assigns.projection.tool_calls, page.tool_calls)
        }

        {:noreply,
         socket
         |> assign(:projection, projection)
         |> assign(:timeline_cursor, page.before_sequence)
         |> stream(:timeline, timeline_items(page.events, projection), at: 0)}

      _invalid_cursor ->
        {:noreply, socket}
    end
  end

  def handle_event("resolve_approval", %{"decision" => decision}, socket) do
    approval_id = socket.assigns.projection.pending_approval_id

    case Sessions.resolve_approval(
           socket.assigns.current_scope,
           socket.assigns.session.id,
           approval_id,
           decision
         ) do
      {:ok, _result} -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, control_error(reason))}
    end
  end

  @impl true
  def handle_info({:session_event, event}, socket) do
    if event.sequence > socket.assigns.projection.last_sequence do
      {:noreply, replay_new_events(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:session_index_changed, session_id}, socket),
    do: {:noreply, refresh_session(socket, session_id)}

  def handle_info(
        {:cluster_membership, _action, :runner, runner_id, _changed, _remaining},
        socket
      ) do
    socket =
      if MapSet.member?(socket.assigns.session_runner_ids, runner_id),
        do: refresh_session_page(socket),
        else: socket

    socket =
      if socket.assigns.session.runner_id == runner_id do
        assign(socket, :runner_online?, Runners.online?(runner_id))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp replay_new_events(socket) do
    socket.assigns.current_scope
    |> Sessions.events_after(
      socket.assigns.session.id,
      socket.assigns.projection.last_sequence
    )
    |> Enum.reduce(socket, &apply_event/2)
  end

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

  defp refresh_session_page(socket) do
    {sessions, cursor} = Sessions.list_sessions_page(socket.assigns.current_scope)

    sessions =
      include_selected_session(sessions, socket.assigns.current_scope, socket.assigns.session.id)

    socket
    |> assign(:sessions_cursor, cursor)
    |> assign(:session_runner_ids, runner_ids(sessions))
    |> stream(:sessions, sessions, reset: true)
  end

  defp apply_event(event, socket) do
    projection =
      event
      |> Projection.apply_event(socket.assigns.projection)
      |> Map.put(:messages, [])

    socket
    |> assign(:projection, projection)
    |> update_pending_approval(event)
    |> update_diff(event)
    |> stream_event(event, projection)
  end

  defp stream_event(socket, %{type: type} = event, _projection) when type in @message_types,
    do: stream_insert(socket, :timeline, message_item(event), limit: -@timeline_page_size)

  defp stream_event(socket, %{type: type, payload: payload}, projection)
       when type in @tool_types do
    tool = Map.fetch!(projection.tool_calls, payload["tool_call_id"])

    if type == "tool_requested",
      do: stream_insert(socket, :timeline, tool_item(tool), limit: -@timeline_page_size),
      else: stream_insert(socket, :timeline, tool_item(tool))
  end

  defp stream_event(socket, _event, _projection), do: socket

  defp update_pending_approval(socket, %{type: "approval_requested"} = event),
    do: assign(socket, :pending_approval, event.payload)

  defp update_pending_approval(socket, %{type: "approval_resolved"}),
    do: assign(socket, :pending_approval, nil)

  defp update_pending_approval(socket, _event), do: socket

  defp update_diff(socket, %{type: "tool_completed", payload: %{"name" => "git_diff"}} = event),
    do: assign(socket, :diff, diff_content(event.payload))

  defp update_diff(socket, _event), do: socket

  defp pending_approval(_scope, %{status: status}) when status != "awaiting_approval", do: nil

  defp pending_approval(scope, session) do
    case Sessions.pending_approval_event(scope, session.id) do
      nil -> nil
      event -> event.payload
    end
  end

  defp latest_diff(scope, session_id) do
    case Sessions.latest_completed_tool_event(scope, session_id, "git_diff") do
      nil -> %{content: "", truncated?: false}
      event -> diff_content(event.payload)
    end
  end

  defp diff_content(payload) do
    case payload["output"] do
      %{"content" => content} = output when is_binary(content) ->
        %{content: content, truncated?: output["truncated"] == true, unavailable?: false}

      %{"response" => %{"diff" => diff} = response} when is_binary(diff) ->
        %{content: diff, truncated?: response["truncated"] == true, unavailable?: false}

      nil ->
        %{content: "", truncated?: false, unavailable?: false}

      _invalid ->
        %{content: "", truncated?: false, unavailable?: true}
    end
  end

  defp diff_files(diff) do
    ~r/^diff --git a\/(.+?) b\/(.+)$/m
    |> Regex.scan(diff, capture: :all_but_first)
    |> Enum.map(fn [_old_path, path] -> path end)
    |> Enum.uniq()
  end

  defp changed_file_count(diff) do
    suffix = if diff.truncated?, do: "+", else: ""
    "#{length(diff_files(diff.content))}#{suffix}"
  end

  defp timeline_items(events, projection) do
    {items, _seen_tools} =
      Enum.reduce(events, {[], MapSet.new()}, &collect_timeline_item(&1, &2, projection))

    Enum.reverse(items)
  end

  defp collect_timeline_item(%{type: type} = event, {items, seen_tools}, _projection)
       when type in @message_types,
       do: {[message_item(event) | items], seen_tools}

  defp collect_timeline_item(%{type: type} = event, {items, seen_tools}, projection)
       when type in @tool_types do
    tool_call_id = event.payload["tool_call_id"]

    if MapSet.member?(seen_tools, tool_call_id) do
      {items, seen_tools}
    else
      tool = Map.fetch!(projection.tool_calls, tool_call_id)
      {[tool_item(tool) | items], MapSet.put(seen_tools, tool_call_id)}
    end
  end

  defp collect_timeline_item(_event, accumulator, _projection), do: accumulator

  defp message_item(event), do: %{id: "message-#{event.id}", kind: :message, value: event}

  defp tool_item(tool),
    do: %{id: "tool-#{tool["tool_call_id"]}", kind: :tool, value: tool}

  defp include_selected_session(sessions, scope, selected_session_id) do
    if Enum.any?(sessions, &(&1.id == selected_session_id)),
      do: sessions,
      else: [Sessions.get_session_for_index(scope, selected_session_id) | sessions]
  end

  defp runner_ids(sessions), do: sessions |> Enum.map(& &1.runner_id) |> MapSet.new()

  defp tool_output(%{"output" => output}), do: format_output(output)
  defp tool_output(%{"error" => error}), do: error
  defp tool_output(_tool), do: ""

  defp format_output(%{"output" => chunks}) when is_list(chunks) do
    Enum.map_join(chunks, "", &(&1["content"] || ""))
  end

  defp format_output(%{"content" => content}) when is_binary(content), do: content
  defp format_output(output) when is_binary(output), do: output
  defp format_output(output), do: Jason.encode!(output, pretty: true)

  defp repository_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp repository_name(%{workspace_root: root}), do: Path.basename(root)

  defp control_error(:turn_in_progress), do: "Wait for the current turn to finish"
  defp control_error(:offline), do: "The runner is offline"
  defp control_error(:approval_not_pending), do: "This approval is no longer pending"
  defp control_error(reason), do: "Unable to control session: #{inspect(reason)}"
end
