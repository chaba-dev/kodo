defmodule Kodo.Sessions.Recovery do
  @moduledoc "Restores active coordinators and reconciles durable legacy drain intent."

  use GenServer

  alias Kodo.Cluster.InstanceManager
  alias Kodo.Sessions

  @retry_interval 1_000

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def recover_active_sessions do
    Sessions.list_active_sessions()
    |> Enum.map(& &1.id)
    |> recover_sessions()

    :ok
  end

  @impl true
  def init(_opts) do
    with :ok <- mark_placement_ready() do
      recover_active_sessions()
      schedule_retry()
      {:ok, %{}}
    end
  end

  @impl true
  def handle_info(:retry, state) do
    recover_active_sessions()
    schedule_retry()
    {:noreply, state}
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

  defp schedule_retry do
    if Process.whereis(InstanceManager), do: Process.send_after(self(), :retry, @retry_interval)
    :ok
  end
end
