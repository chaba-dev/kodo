defmodule Kodo.Sessions.ActiveSession do
  @moduledoc "Supervised, disposable coordinator for one durable session."

  use GenServer

  alias Kodo.Agent.Loop
  alias Kodo.Sessions
  alias Kodo.Sessions.Projection

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  def child_spec(session_id) do
    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [session_id]},
      restart: :temporary
    }
  end

  def state(pid), do: GenServer.call(pid, :state)
  def start_turn(pid, content), do: GenServer.call(pid, {:start_turn, content})
  def cancel(pid), do: GenServer.call(pid, :cancel)

  @impl true
  def init(session_id) do
    Process.flag(:trap_exit, true)
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session_id}")
    projection = recover(session_id)
    {:ok, %{projection: projection, task: nil}}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state.projection, state}

  def handle_call({:start_turn, content}, _from, %{task: nil} = state)
      when is_binary(content) and content != "" do
    with {:ok, _event} <-
           Sessions.append_event(state.projection.id, "user_message", %{
             "role" => "user",
             "content" => content
           }),
         {:ok, _status} <- Sessions.set_status(state.projection.id, "running") do
      task = Task.async(fn -> Loop.run(state.projection.id) end)
      {:reply, :ok, %{state | task: task}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start_turn, _content}, _from, state),
    do: {:reply, {:error, :turn_in_progress}, state}

  def handle_call(:cancel, _from, %{task: nil} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call(:cancel, _from, state) do
    case Task.shutdown(state.task, :brutal_kill) do
      {:ok, result} ->
        finalize(state.projection.id, result)
        {:reply, {:error, :already_finished}, %{state | task: nil}}

      {:exit, reason} ->
        finalize(state.projection.id, {:error, {:task_exit, reason}})
        {:reply, {:error, :already_finished}, %{state | task: nil}}

      nil ->
        case Sessions.cancel_session(state.projection.id) do
          {:ok, _cancelled} -> {:reply, :ok, %{state | task: nil}}
          {:error, reason} -> {:reply, {:error, reason}, %{state | task: nil}}
        end
    end
  end

  @impl true
  def handle_info({:session_event, event}, state) do
    projection = apply_committed_events(event, state.projection)
    {:noreply, %{state | projection: projection}}
  end

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finalize(state.projection.id, result)
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    finalize(state.projection.id, {:error, {:task_exit, reason}})
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp finalize(session_id, {:ok, _answer}) do
    _ = Sessions.set_status(session_id, "completed")
  end

  defp finalize(session_id, {:error, reason}) do
    _ = Sessions.append_event(session_id, "session_failed", %{"reason" => inspect(reason)})
    _ = Sessions.set_status(session_id, "failed")
  end

  defp recover(session_id) do
    projection = session_id |> Sessions.events_after() |> Projection.from_events()

    if projection.status in ["running", "awaiting_approval"] do
      _ =
        Sessions.append_event(session_id, "session_failed", %{
          "reason" => "active coordinator restarted during a turn"
        })

      _ = Sessions.set_status(session_id, "failed")
      session_id |> Sessions.events_after() |> Projection.from_events()
    else
      projection
    end
  end

  defp apply_committed_events(event, projection) when event.sequence <= projection.last_sequence,
    do: projection

  defp apply_committed_events(_event, projection) do
    projection.id
    |> Sessions.events_after(projection.last_sequence)
    |> Enum.reduce(projection, &Projection.apply_event/2)
  end

  def via(session_id), do: {:via, Registry, {Kodo.SessionRegistry, session_id}}
end
