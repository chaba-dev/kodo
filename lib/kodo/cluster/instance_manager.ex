defmodule Kodo.Cluster.InstanceManager do
  @moduledoc "Registers and maintains this BEAM instance's durable boot incarnation."

  use GenServer

  alias Kodo.Cluster.Instances

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def current_instance(server \\ __MODULE__), do: GenServer.call(server, :current_instance)
  def begin_drain(server \\ __MODULE__), do: GenServer.call(server, :begin_drain)

  @impl true
  def init(opts) do
    config = Keyword.merge(Application.fetch_env!(:kodo, __MODULE__), opts)

    attrs = %{
      boot_id: Keyword.get(config, :boot_id, Ecto.UUID.generate()),
      node_name: Keyword.get(config, :node_name, Atom.to_string(node())),
      artifact_revision: Keyword.fetch!(config, :artifact_revision),
      deployment_generation: Keyword.fetch!(config, :deployment_generation),
      ready: true,
      draining: false,
      capacity: Keyword.get(config, :capacity, System.schedulers_online()),
      protocol_capabilities: Keyword.fetch!(config, :protocol_capabilities)
    }

    case Instances.register_current(attrs) do
      {:ok, instance} ->
        schedule_heartbeat(Keyword.fetch!(config, :heartbeat_interval))
        {:ok, %{instance: instance, heartbeat_interval: config[:heartbeat_interval]}}

      {:error, reason} ->
        {:stop, {:instance_registration_failed, reason}}
    end
  end

  @impl true
  def handle_call(:current_instance, _from, state), do: {:reply, state.instance, state}

  def handle_call(:begin_drain, _from, state) do
    case Instances.begin_drain(state.instance) do
      {:ok, instance} -> {:reply, {:ok, instance}, %{state | instance: instance}}
      {:error, changeset} -> {:reply, {:error, changeset}, state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    case Instances.heartbeat(state.instance) do
      {:ok, instance} ->
        schedule_heartbeat(state.heartbeat_interval)
        {:noreply, %{state | instance: instance}}

      {:error, reason} ->
        {:stop, {:instance_heartbeat_failed, reason}, state}
    end
  end

  defp schedule_heartbeat(:infinity), do: :ok
  defp schedule_heartbeat(interval), do: Process.send_after(self(), :heartbeat, interval)
end
