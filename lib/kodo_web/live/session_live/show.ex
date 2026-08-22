defmodule KodoWeb.SessionLive.Show do
  use KodoWeb, :live_view

  alias Kodo.Cluster.Discovery
  alias Kodo.Runners
  alias Kodo.Sessions
  alias Kodo.Sessions.Projection

  @message_types ["user_message", "assistant_message_completed"]
  @tool_types ["tool_requested", "tool_started", "tool_completed", "tool_failed"]

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
      :ok = Sessions.subscribe_index()
    end

    events = Sessions.events_after(socket.assigns.current_scope, session.id)
    projection = Projection.from_events(events)

    socket =
      socket
      |> stream_configure(:timeline, dom_id: & &1.id)
      |> assign(:page_title, session.title)
      |> assign(:session, session)
      |> assign(:runner, Runners.get_runner(session.runner_id))
      |> assign(:runner_online?, Runners.online?(session.runner_id))
      |> assign(:projection, projection)
      |> assign(:pending_approval, pending_approval(events, projection.pending_approval_id))
      |> assign(:diff, latest_diff(events))
      |> assign(:message_form, to_form(%{"content" => ""}, as: :message))
      |> stream(:sessions, Sessions.list_sessions(socket.assigns.current_scope))
      |> stream(:timeline, timeline_items(events, projection))

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

  def handle_info(:session_index_changed, socket), do: {:noreply, refresh_sessions(socket)}

  def handle_info(
        {:cluster_membership, _action, :runner, runner_id, _changed, _remaining},
        socket
      ) do
    socket = refresh_sessions(socket)

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

  defp refresh_sessions(socket) do
    stream(socket, :sessions, Sessions.list_sessions(socket.assigns.current_scope), reset: true)
  end

  defp apply_event(event, socket) do
    projection = Projection.apply_event(event, socket.assigns.projection)

    socket
    |> assign(:projection, projection)
    |> update_pending_approval(event)
    |> update_diff(event)
    |> stream_event(event, projection)
  end

  defp stream_event(socket, %{type: type} = event, _projection) when type in @message_types,
    do: stream_insert(socket, :timeline, message_item(event))

  defp stream_event(socket, %{type: type, payload: payload}, projection)
       when type in @tool_types do
    tool = Map.fetch!(projection.tool_calls, payload["tool_call_id"])
    stream_insert(socket, :timeline, tool_item(tool))
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

  defp pending_approval(_events, nil), do: nil

  defp pending_approval(events, approval_id) do
    events
    |> Enum.find(&(&1.type == "approval_requested" and &1.payload["approval_id"] == approval_id))
    |> case do
      nil -> nil
      event -> event.payload
    end
  end

  defp latest_diff(events) do
    events
    |> Enum.reverse()
    |> Enum.find(&(&1.type == "tool_completed" and &1.payload["name"] == "git_diff"))
    |> case do
      nil -> %{content: "", truncated?: false}
      event -> diff_content(event.payload)
    end
  end

  defp diff_content(payload) do
    output = payload["output"] || %{}

    %{
      content: output["content"] || get_in(output, ["response", "diff"]) || "",
      truncated?: output["truncated"] == true || get_in(output, ["response", "truncated"]) == true
    }
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
