defmodule Kodo.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Do not advertise a policy that connected runners must reject after authenticating.
    _limits = Kodo.RunnerProtocol.validate_limits!()

    children = [
      KodoWeb.Telemetry,
      Kodo.Repo,
      {Kodo.Cluster.InstanceManager, boot_id: Ecto.UUID.generate()},
      {DNSCluster, query: Application.get_env(:kodo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Kodo.PubSub},
      Kodo.Cluster.Discovery,
      Kodo.Cluster.DiscoveryMonitor,
      {Registry, keys: :unique, name: Kodo.RunnerRegistry},
      {Registry, keys: :unique, name: Kodo.SessionRegistry},
      {DynamicSupervisor, name: Kodo.SessionSupervisor, strategy: :one_for_one},
      Kodo.Sessions.Recovery,
      # Start to serve requests, typically the last entry
      KodoWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :rest_for_one, name: Kodo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def prep_stop(state) do
    if Process.whereis(Kodo.Cluster.InstanceManager) do
      _ = Kodo.Cluster.InstanceManager.begin_drain()
    end

    state
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KodoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
