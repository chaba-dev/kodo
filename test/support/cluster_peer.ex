defmodule Kodo.Test.ClusterPeer do
  @moduledoc false

  def start(repo_config, instance_options, agent_budgets, test_pid) do
    Application.put_env(:kodo, Kodo.Repo, repo_config)
    Application.put_env(:kodo, Kodo.Cluster.InstanceManager, instance_options)
    Application.put_env(:kodo, :agent_budgets, agent_budgets)
    Application.put_env(:kodo, :llm_adapter, Kodo.Test.FakeLLM)
    Application.put_env(:kodo, :fake_llm_test_pid, test_pid)
    {:ok, _applications} = Application.ensure_all_started(:ecto_sql)
    {:ok, _applications} = Application.ensure_all_started(:phoenix_pubsub)

    children = [
      {Kodo.Repo, pool: DBConnection.ConnectionPool, pool_size: 8},
      {Phoenix.PubSub, name: Kodo.PubSub},
      %{id: Kodo.Cluster.Discovery, start: {:pg, :start_link, [Kodo.Cluster.Discovery.scope()]}},
      {Registry, keys: :unique, name: Kodo.RunnerRegistry},
      {Registry, keys: :unique, name: Kodo.SessionRegistry},
      {DynamicSupervisor, name: Kodo.SessionSupervisor, strategy: :one_for_one},
      {Kodo.Cluster.InstanceManager, Keyword.put(instance_options, :ready, false)},
      {Task.Supervisor, name: Kodo.ControlPlaneTaskSupervisor},
      {Kodo.Sessions.Recovery, []}
    ]

    with {:ok, supervisor} <- Supervisor.start_link(children, strategy: :one_for_one) do
      Process.unlink(supervisor)
      {:ok, supervisor}
    end
  end
end
