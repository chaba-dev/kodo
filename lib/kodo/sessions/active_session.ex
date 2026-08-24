defmodule Kodo.Sessions.ActiveSession do
  @moduledoc "Supervised, disposable coordinator for one durable session."

  use GenServer

  alias Kodo.Agent.Loop
  alias Kodo.Cluster.Discovery
  alias Kodo.Cluster.InstanceManager
  alias Kodo.Sessions
  alias Kodo.Sessions.Projection

  def start_link({session_id, expected_boot_id}) do
    GenServer.start_link(__MODULE__, {session_id, expected_boot_id}, name: via(session_id))
  end

  def start_link({session_id, expected_boot_id, previous_ownership}) do
    GenServer.start_link(
      __MODULE__,
      {session_id, expected_boot_id, previous_ownership},
      name: via(session_id)
    )
  end

  def child_spec(init_arg) do
    session_id = elem(init_arg, 0)

    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [init_arg]},
      restart: :transient
    }
  end

  def state(pid), do: GenServer.call(pid, :state)

  def start_turn(pid, content, client_request_id \\ nil),
    do: GenServer.call(pid, {:start_turn, content, client_request_id})

  def cancel(pid), do: GenServer.call(pid, :cancel)

  def begin_drain(pid, owner_boot_id, timeout),
    do: GenServer.call(pid, {:begin_drain, owner_boot_id}, timeout)

  @impl true
  def init({session_id, expected_boot_id}) do
    init_session(session_id, expected_boot_id, nil)
  end

  def init({session_id, expected_boot_id, previous_ownership}) do
    init_session(session_id, expected_boot_id, previous_ownership)
  end

  defp init_session(session_id, expected_boot_id, previous_ownership) do
    Process.flag(:trap_exit, true)
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session_id}")

    with {:ok, boot_id, instance_manager_ref} <- monitor_instance_manager(expected_boot_id),
         {:ok, ownership} <- acquire_ownership(session_id, boot_id, previous_ownership),
         :ok <- Discovery.join_session(session_id),
         projection = recover(session_id),
         :ok <- renew_runner_authority(projection.runner_id, ownership) do
      task = maybe_start_loop(projection, ownership)
      schedule_authority_check(ownership)

      {:ok,
       %{
         projection: projection,
         task: task,
         ownership: ownership,
         instance_manager_ref: instance_manager_ref
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state.projection, state}

  def handle_call(
        {:begin_drain, owner_boot_id},
        from,
        %{ownership: %{owner_boot_id: owner_boot_id}, task: task} = state
      )
      when not is_nil(task) do
    send(task.pid, :rehoming_requested)
    {:noreply, Map.update(state, :drain_waiters, [from], &[from | &1])}
  end

  def handle_call({:begin_drain, owner_boot_id}, _from, state) do
    result = if state.ownership.owner_boot_id == owner_boot_id, do: :ok, else: :not_owned
    {:reply, result, state}
  end

  def handle_call(
        {:start_turn, content, client_request_id},
        _from,
        %{task: nil, projection: %{status: status}} = state
      )
      when status not in ["running", "awaiting_approval"] and is_binary(content) and content != "" do
    case Sessions.begin_turn(state.projection.id, content, client_request_id,
           ownership: state.ownership
         ) do
      {:ok, _events} ->
        task = start_loop(state.projection.id, state.ownership)
        {:reply, :ok, %{state | task: task}}

      {:error, :stale_ownership} = error ->
        {:stop, :normal, error, stop_task(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start_turn, content, client_request_id}, _from, state) do
    case Sessions.begin_turn(state.projection.id, content, client_request_id,
           ownership: state.ownership
         ) do
      {:ok, []} ->
        {:reply, :ok, state}

      {:error, :stale_ownership} = error ->
        {:stop, :normal, error, stop_task(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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
        case Sessions.cancel_session(state.projection.id, ownership: state.ownership) do
          {:ok, _cancelled} ->
            {:stop, :normal, :ok, %{state | task: nil}}

          {:error, :stale_ownership} = error ->
            {:stop, :normal, error, stop_task(state)}

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

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{instance_manager_ref: ref} = state
      ) do
    {:stop, :normal, stop_task(state)}
  end

  def handle_info(:check_authority, state) do
    case renew_runner_authority(state.projection.runner_id, state.ownership) do
      :ok ->
        schedule_authority_check(state.ownership)
        {:noreply, state}

      {:error, _reason} ->
        {:stop, :normal, stop_task(state)}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp finalize(session_id, {:ok, _answer}, ownership) do
    Sessions.complete_session(session_id, ownership: ownership)
  end

  defp finalize(session_id, {:error, reason}, ownership) do
    Sessions.fail_session(session_id, reason, ownership: ownership)
  end

  defp finish_task(state, {:error, :rehoming_requested}) do
    state = %{state | task: nil}

    case Sessions.rehome_active_session(state.ownership) do
      {:ok, _pid} ->
        reply_drain_waiters(state, :ok)
        {:stop, :normal, state}

      {:error, reason} ->
        reply_drain_waiters(state, {:error, reason})
        task = start_loop(state.projection.id, state.ownership)
        {:noreply, state |> Map.put(:task, task) |> Map.delete(:drain_waiters)}
    end
  end

  defp finish_task(state, result) do
    finish_regular_task(state, result)
  end

  defp finish_regular_task(state, result) do
    case finalize(state.projection.id, result, state.ownership) do
      {:ok, _events} ->
        reply_drain_waiters(state, :ok)
        {:stop, :normal, state |> Map.put(:task, nil) |> Map.delete(:drain_waiters)}

      {:error, :session_not_active} ->
        reply_drain_waiters(state, :ok)
        {:stop, :normal, state |> Map.put(:task, nil) |> Map.delete(:drain_waiters)}

      {:error, :stale_ownership} ->
        reply_drain_waiters(state, {:error, :stale_ownership})
        {:stop, :normal, stop_task(state)}

      {:error, reason} ->
        reply_drain_waiters(state, {:error, reason})
        {:stop, {:session_finalization_failed, reason}, state}
    end
  end

  defp finish_cancelled_task(state, result) do
    case finalize(state.projection.id, result, state.ownership) do
      {:ok, _events} ->
        {:stop, :normal, {:error, :already_finished}, %{state | task: nil}}

      {:error, :session_not_active} ->
        {:stop, :normal, {:error, :already_finished}, %{state | task: nil}}

      {:error, :stale_ownership} = error ->
        {:stop, :normal, error, stop_task(state)}

      {:error, reason} ->
        {:stop, {:session_finalization_failed, reason}, {:error, reason}, state}
    end
  end

  defp recover(session_id) do
    session_id |> Sessions.events_after() |> Projection.from_events()
  end

  defp maybe_start_loop(%{status: status, id: session_id}, ownership)
       when status in ["running", "awaiting_approval"],
       do: start_loop(session_id, ownership)

  defp maybe_start_loop(_projection, _ownership), do: nil

  defp start_loop(session_id, ownership) do
    Task.async(fn -> Loop.run(session_id, ownership: ownership) end)
  end

  defp stop_task(%{task: nil} = state), do: state

  defp stop_task(state) do
    _ = Task.shutdown(state.task, :brutal_kill)
    %{state | task: nil}
  end

  defp monitor_instance_manager(nil) do
    if Process.whereis(InstanceManager),
      do: {:error, :target_boot_mismatch},
      else: {:ok, nil, nil}
  end

  defp monitor_instance_manager(expected_boot_id) do
    with pid when is_pid(pid) <- Process.whereis(InstanceManager),
         ^expected_boot_id <- InstanceManager.current_boot_id(pid) do
      {:ok, expected_boot_id, Process.monitor(pid)}
    else
      _mismatch -> {:error, :target_boot_mismatch}
    end
  catch
    :exit, _reason -> {:error, :coordinator_unavailable}
  end

  defp acquire_ownership(session_id, boot_id, nil),
    do: Sessions.claim_ownership(session_id, boot_id)

  defp acquire_ownership(_session_id, boot_id, previous_ownership),
    do: Sessions.transfer_ownership(previous_ownership, boot_id)

  defp reply_drain_waiters(state, reply) do
    Enum.each(Map.get(state, :drain_waiters, []), &GenServer.reply(&1, reply))
  end

  defp schedule_authority_check(%{owner_boot_id: nil}), do: :ok

  defp schedule_authority_check(_ownership) do
    interval =
      :kodo
      |> Application.fetch_env!(InstanceManager)
      |> Keyword.fetch!(:heartbeat_interval)

    if interval != :infinity, do: Process.send_after(self(), :check_authority, interval)
    :ok
  end

  defp renew_runner_authority(_runner_id, %{owner_boot_id: nil}), do: :ok

  defp renew_runner_authority(runner_id, ownership) do
    case Sessions.dispatch_if_owner(ownership, fn ->
           Kodo.Runners.renew_authority(
             runner_id,
             Kodo.RunnerProtocol.authority_lease(ownership)
           )
         end) do
      {:error, :offline} -> :ok
      result -> result
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
