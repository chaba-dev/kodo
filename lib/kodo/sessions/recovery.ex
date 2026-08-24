defmodule Kodo.Sessions.Recovery do
  @moduledoc "Elects one database-backed recovery sweeper for active durable sessions."

  use GenServer

  alias Kodo.Cluster.InstanceManager
  alias Kodo.ControlPlaneTelemetry
  alias Kodo.Repo
  alias Kodo.Sessions

  @lease_key "kodo:active-session-recovery"
  @try_lock_sql "SELECT pg_try_advisory_lock(hashtextextended($1, 0)), pg_backend_pid()"
  @unlock_sql "SELECT pg_advisory_unlock(hashtextextended($1, 0))"
  @default_config [sweep_interval: 5_000, election_retry_interval: 1_000]

  def start_link(opts) do
    config = Keyword.merge(Application.get_env(:kodo, __MODULE__, @default_config), opts)
    {name, config} = Keyword.pop(config, :name, __MODULE__)
    GenServer.start_link(__MODULE__, config, if(name, do: [name: name], else: []))
  end

  def recover_active_sessions do
    Sessions.list_active_sessions()
    |> Enum.map(& &1.id)
    |> recover_sessions()

    :ok
  end

  @impl true
  def init(config) do
    with :ok <- mark_placement_ready() do
      state = %{
        coordinated?: Keyword.get(config, :coordinated, Process.whereis(InstanceManager) != nil),
        election_retry_interval: Keyword.fetch!(config, :election_retry_interval),
        lease_backend: Keyword.get(config, :lease_backend, default_lease_backend()),
        lease_backend_pid: nil,
        leader?: false,
        lease_pid: nil,
        lease_ref: nil,
        sweep: Keyword.get(config, :sweep, &recover_active_sessions/0),
        sweep_interval: Keyword.fetch!(config, :sweep_interval),
        sweep_task: nil,
        validation_ref: nil
      }

      if state.coordinated? do
        send(self(), :elect)
      else
        recover_active_sessions()
      end

      {:ok, state}
    end
  end

  @impl true
  def handle_info(:elect, %{lease_pid: nil} = state) do
    parent = self()
    backend = state.lease_backend
    check_interval = state.election_retry_interval
    {pid, ref} = spawn_monitor(fn -> hold_lease(parent, backend, check_interval) end)
    {:noreply, %{state | lease_pid: pid, lease_ref: ref}}
  end

  def handle_info(:elect, state), do: {:noreply, state}

  def handle_info(
        {:recovery_lease, pid, true, backend_pid},
        %{lease_pid: pid} = state
      ) do
    state = %{state | leader?: true, lease_backend_pid: backend_pid}
    {:noreply, validate_lease(state)}
  end

  def handle_info({:recovery_lease, pid, false, nil}, %{lease_pid: pid} = state),
    do: {:noreply, state}

  def handle_info(
        {:recovery_lease_valid, pid, validation_ref},
        %{lease_pid: pid, validation_ref: validation_ref} = state
      ) do
    {:noreply, state |> Map.put(:validation_ref, nil) |> start_sweep()}
  end

  def handle_info(
        {task_ref, :ok},
        %{sweep_task: %Task{ref: task_ref}} = state
      ) do
    Process.demonitor(task_ref, [:flush])
    schedule_sweep(state.sweep_interval)
    {:noreply, %{state | sweep_task: nil}}
  end

  def handle_info(
        {task_ref, result},
        %{sweep_task: %Task{ref: task_ref}} = state
      ) do
    Process.demonitor(task_ref, [:flush])
    {:stop, {:recovery_sweep_failed, result}, %{state | sweep_task: nil}}
  end

  def handle_info(:sweep, %{leader?: true, validation_ref: nil} = state),
    do: {:noreply, validate_lease(state)}

  def handle_info(:sweep, state), do: {:noreply, state}

  # Retain explicit retries for uncoordinated tests and single-process recovery tools.
  def handle_info(:retry, %{coordinated?: false} = state) do
    recover_active_sessions()
    {:noreply, state}
  end

  def handle_info(:retry, %{leader?: true, validation_ref: nil} = state),
    do: {:noreply, validate_lease(state)}

  def handle_info(:retry, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{lease_pid: pid, lease_ref: ref} = state) do
    Process.send_after(self(), :elect, state.election_retry_interval)
    state = stop_sweep(state)

    {:noreply,
     %{
       state
       | leader?: false,
         lease_backend_pid: nil,
         lease_pid: nil,
         lease_ref: nil,
         validation_ref: nil
     }}
  end

  def handle_info(
        {:DOWN, task_ref, :process, task_pid, reason},
        %{sweep_task: %Task{pid: task_pid, ref: task_ref}} = state
      ) do
    {:stop, {:recovery_sweep_failed, reason}, %{state | sweep_task: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    _state = stop_sweep(state)
    :ok
  end

  defp recover_sessions(session_ids) do
    Enum.filter(session_ids, fn session_id ->
      case Sessions.get_session(session_id) do
        %{status: status} when status in ["running", "awaiting_approval"] ->
          not match?({:ok, _pid}, Sessions.reconcile_started(session_id))

        _inactive_or_missing ->
          false
      end
    end)
  end

  defp mark_placement_ready do
    case Process.whereis(InstanceManager) do
      nil ->
        :ok

      _pid ->
        case InstanceManager.mark_ready() do
          {:ok, _instance} -> :ok
          {:error, reason} -> {:stop, {:placement_readiness_failed, reason}}
        end
    end
  end

  defp default_lease_backend,
    do: if(Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox, do: :test, else: :database)

  defp hold_lease(parent, :test, check_interval),
    do: hold_test_lease(parent, check_interval)

  defp hold_lease(parent, :database, check_interval),
    do: run_on_database_connection(fn -> hold_database_lease(parent, check_interval) end)

  defp hold_test_lease(parent, check_interval) do
    lock_id = {{__MODULE__, @lease_key}, self()}
    acquired? = :global.set_lock(lock_id, [node()], 0)
    send(parent, {:recovery_lease, self(), acquired?, nil})

    if acquired? do
      test_lease_loop(parent, Process.monitor(parent), check_interval)
      :global.del_lock(lock_id, [node()])
    end
  end

  defp hold_database_lease(parent, check_interval) do
    election_opts = ControlPlaneTelemetry.repo_options(:recovery_election)
    [[acquired?, backend_pid]] = Repo.query!(@try_lock_sql, [@lease_key], election_opts).rows

    if acquired? do
      send(parent, {:recovery_lease, self(), true, backend_pid})
      database_lease_loop(parent, Process.monitor(parent), backend_pid, check_interval)
      _ = Repo.query(@unlock_sql, [@lease_key], election_opts)
    else
      send(parent, {:recovery_lease, self(), false, nil})
    end
  end

  defp test_lease_loop(parent, parent_ref, check_interval) do
    receive do
      {:validate_recovery_lease, ^parent, validation_ref} ->
        send(parent, {:recovery_lease_valid, self(), validation_ref})
        test_lease_loop(parent, parent_ref, check_interval)

      {:DOWN, ^parent_ref, :process, ^parent, _reason} ->
        :ok
    after
      check_interval -> test_lease_loop(parent, parent_ref, check_interval)
    end
  end

  defp database_lease_loop(parent, parent_ref, backend_pid, check_interval) do
    receive do
      {:validate_recovery_lease, ^parent, validation_ref} ->
        validate_database_lease!(backend_pid)
        send(parent, {:recovery_lease_valid, self(), validation_ref})
        database_lease_loop(parent, parent_ref, backend_pid, check_interval)

      {:DOWN, ^parent_ref, :process, ^parent, _reason} ->
        :ok
    after
      check_interval ->
        validate_database_lease!(backend_pid)
        database_lease_loop(parent, parent_ref, backend_pid, check_interval)
    end
  end

  defp validate_database_lease!(backend_pid) do
    opts = ControlPlaneTelemetry.repo_options(:recovery_lease)

    case Repo.query("SELECT pg_backend_pid()", [], opts) do
      {:ok, %{rows: [[^backend_pid]]}} -> :ok
      {:ok, %{rows: [[replacement_pid]]}} -> exit({:recovery_connection_changed, replacement_pid})
      {:error, reason} -> exit({:recovery_connection_lost, reason})
    end
  end

  defp run_on_database_connection(fun) do
    if Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox,
      do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun),
      else: Repo.checkout(fun, timeout: :infinity)
  end

  defp validate_lease(state) do
    validation_ref = make_ref()
    send(state.lease_pid, {:validate_recovery_lease, self(), validation_ref})
    %{state | validation_ref: validation_ref}
  end

  defp start_sweep(%{sweep_task: nil} = state) do
    recovery = self()
    sweep = state.sweep

    task =
      Task.Supervisor.async_nolink(Kodo.ControlPlaneTaskSupervisor, fn ->
        run_sweep(recovery, sweep)
      end)

    %{state | sweep_task: task}
  end

  defp run_sweep(recovery, sweep) do
    recovery_ref = Process.monitor(recovery)
    owner = self()
    worker = spawn_link(fn -> send(owner, {:recovery_sweep_result, self(), sweep.()}) end)

    receive do
      {:recovery_sweep_result, ^worker, result} ->
        Process.demonitor(recovery_ref, [:flush])
        result

      {:DOWN, ^recovery_ref, :process, ^recovery, _reason} ->
        Process.exit(worker, :kill)
        exit(:normal)
    end
  end

  defp stop_sweep(%{sweep_task: nil} = state), do: state

  defp stop_sweep(%{sweep_task: task} = state) do
    _result = Task.shutdown(task, :brutal_kill)
    %{state | sweep_task: nil}
  end

  defp schedule_sweep(:infinity), do: :ok
  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)
end
