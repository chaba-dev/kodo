defmodule Kodo.Sessions.Recovery do
  @moduledoc "Elects one database-backed recovery sweeper for active durable sessions."

  use GenServer

  alias Kodo.Cluster.InstanceManager
  alias Kodo.Repo
  alias Kodo.Sessions

  @lease_key "kodo:active-session-recovery"
  @try_lock_sql "SELECT pg_try_advisory_lock(hashtextextended($1, 0))"
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
        leader?: false,
        lease_pid: nil,
        lease_ref: nil,
        sweep_interval: Keyword.fetch!(config, :sweep_interval)
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
    {pid, ref} = spawn_monitor(fn -> hold_lease(parent) end)
    {:noreply, %{state | lease_pid: pid, lease_ref: ref}}
  end

  def handle_info(:elect, state), do: {:noreply, state}

  def handle_info({:recovery_lease, pid, true}, %{lease_pid: pid} = state) do
    recover_active_sessions()
    schedule_sweep(state.sweep_interval)
    {:noreply, %{state | leader?: true}}
  end

  def handle_info({:recovery_lease, pid, false}, %{lease_pid: pid} = state),
    do: {:noreply, state}

  def handle_info(:sweep, %{leader?: true} = state) do
    recover_active_sessions()
    schedule_sweep(state.sweep_interval)
    {:noreply, state}
  end

  def handle_info(:sweep, state), do: {:noreply, state}

  # Retain explicit retries for uncoordinated tests and single-process recovery tools.
  def handle_info(:retry, %{coordinated?: false} = state) do
    recover_active_sessions()
    {:noreply, state}
  end

  def handle_info(:retry, %{leader?: true} = state) do
    recover_active_sessions()
    {:noreply, state}
  end

  def handle_info(:retry, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{lease_pid: pid, lease_ref: ref} = state) do
    Process.send_after(self(), :elect, state.election_retry_interval)
    {:noreply, %{state | leader?: false, lease_pid: nil, lease_ref: nil}}
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

  defp hold_lease(parent) do
    if Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox,
      do: hold_test_lease(parent),
      else: hold_database_lease(parent)
  end

  defp hold_test_lease(parent) do
    lock_id = {{__MODULE__, @lease_key}, self()}
    acquired? = :global.set_lock(lock_id, [node()], 0)
    send(parent, {:recovery_lease, self(), acquired?})

    if acquired? do
      wait_for_parent(parent)
      :global.del_lock(lock_id, [node()])
    end
  end

  defp hold_database_lease(parent) do
    Repo.checkout(
      fn ->
        acquired? = Repo.query!(@try_lock_sql, [@lease_key]).rows == [[true]]
        send(parent, {:recovery_lease, self(), acquired?})

        if acquired? do
          wait_for_parent(parent)
          _ = Repo.query!(@unlock_sql, [@lease_key])
        end
      end,
      timeout: :infinity
    )
  end

  defp wait_for_parent(parent) do
    parent_ref = Process.monitor(parent)

    receive do
      {:DOWN, ^parent_ref, :process, ^parent, _reason} -> :ok
    end
  end

  defp schedule_sweep(:infinity), do: :ok
  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)
end
