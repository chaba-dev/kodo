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
      restart: :transient
    }
  end

  def state(pid), do: GenServer.call(pid, :state)

  def start_turn(pid, content, client_request_id \\ nil),
    do: GenServer.call(pid, {:start_turn, content, client_request_id})

  def cancel(pid), do: GenServer.call(pid, :cancel)

  @impl true
  def init(session_id) do
    Process.flag(:trap_exit, true)
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session_id}")
    projection = recover(session_id)

    task =
      if projection.status in ["running", "awaiting_approval"] do
        Task.async(fn -> Loop.run(session_id) end)
      end

    {:ok, %{projection: projection, task: task}}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state.projection, state}

  def handle_call(
        {:start_turn, content, client_request_id},
        _from,
        %{task: nil, projection: %{status: status}} = state
      )
      when status not in ["running", "awaiting_approval"] and is_binary(content) and content != "" do
    with {:ok, _events} <- Sessions.begin_turn(state.projection.id, content, client_request_id) do
      task = Task.async(fn -> Loop.run(state.projection.id) end)
      {:reply, :ok, %{state | task: task}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start_turn, content, client_request_id}, _from, state) do
    case Sessions.begin_turn(state.projection.id, content, client_request_id) do
      {:ok, []} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:cancel, _from, %{task: nil} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call(:cancel, _from, state) do
    case Task.shutdown(state.task, :brutal_kill) do
      {:ok, result} ->
        finish_cancelled_task(state, result)

      {:exit, reason} ->
        finish_cancelled_task(state, {:error, {:task_exit, reason}})

      nil ->
        case Sessions.cancel_session(state.projection.id) do
          {:ok, _cancelled} ->
            {:reply, :ok, %{state | task: nil}}

          {:error, reason} ->
            {:stop, {:cancellation_persistence_failed, reason}, {:error, reason}, state}
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
    finish_task(state, result)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    finish_task(state, {:error, {:task_exit, reason}})
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp finalize(session_id, {:ok, _answer}) do
    Sessions.complete_session(session_id)
  end

  defp finalize(session_id, {:error, reason}) do
    Sessions.fail_session(session_id, reason)
  end

  defp finish_task(state, result) do
    case finalize(state.projection.id, result) do
      {:ok, _events} ->
        {:noreply, %{state | task: nil}}

      {:error, :session_not_active} ->
        {:noreply, %{state | task: nil}}

      {:error, reason} ->
        {:stop, {:session_finalization_failed, reason}, state}
    end
  end

  defp finish_cancelled_task(state, result) do
    case finalize(state.projection.id, result) do
      {:ok, _events} ->
        {:reply, {:error, :already_finished}, %{state | task: nil}}

      {:error, :session_not_active} ->
        {:reply, {:error, :already_finished}, %{state | task: nil}}

      {:error, reason} ->
        {:stop, {:session_finalization_failed, reason}, {:error, reason}, state}
    end
  end

  defp recover(session_id) do
    session_id |> Sessions.events_after() |> Projection.from_events()
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
