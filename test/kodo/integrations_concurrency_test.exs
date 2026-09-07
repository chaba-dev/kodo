defmodule Kodo.IntegrationsConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Kodo.Accounts.Scope
  alias Kodo.AccountsFixtures
  alias Kodo.Integrations
  alias Kodo.Integrations.Integration
  alias Kodo.Repo

  import Ecto.Query

  setup do
    Sandbox.mode(Repo, :auto)
    user = AccountsFixtures.user_fixture()
    supervisor = start_supervised!(Task.Supervisor)

    on_exit(fn ->
      Repo.delete_all(from integration in Integration, where: integration.user_id == ^user.id)
      Repo.delete!(user)
      Sandbox.mode(Repo, :manual)
    end)

    %{scope: Scope.for_user(user), supervisor: supervisor}
  end

  test "simultaneous first connections produce exactly one active account", %{
    scope: scope,
    supervisor: supervisor
  } do
    results =
      ["first", "second"]
      |> Enum.map(fn name ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          Integrations.connect(scope, "openai", "api_key", %{"api_key" => "#{name}-secret"},
            display_name: name
          )
        end)
      end)
      |> Task.await_many()

    assert Enum.all?(results, &match?({:ok, _integration}, &1))
    assert Enum.count(Integrations.list_integrations(scope), & &1.active) == 1
    assert length(Integrations.list_audit_events(scope)) == 2
  end

  test "simultaneous switches complete with one active account", %{
    scope: scope,
    supervisor: supervisor
  } do
    {:ok, _first} = connect(scope, "first")
    {:ok, second} = connect(scope, "second")
    {:ok, third} = connect(scope, "third")

    results =
      [second, third]
      |> Enum.map(fn integration ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          Integrations.activate(scope, integration.id, integration.credential_generation)
        end)
      end)
      |> Task.await_many()

    assert Enum.all?(results, &match?({:ok, _integration}, &1))
    assert Enum.count(Integrations.list_integrations(scope), & &1.active) == 1

    assert Enum.count(
             Integrations.list_audit_events(scope),
             &(&1.event_type == "integration_activated")
           ) == 2
  end

  test "connection racing activation cannot take over the explicit selection", %{
    scope: scope,
    supervisor: supervisor
  } do
    {:ok, _first} = connect(scope, "first")
    {:ok, selected} = connect(scope, "selected")

    connect_task = Task.Supervisor.async_nolink(supervisor, fn -> connect(scope, "added") end)

    activate_task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Integrations.activate(scope, selected.id, selected.credential_generation)
      end)

    assert {:ok, added} = Task.await(connect_task)
    assert {:ok, activated} = Task.await(activate_task)
    refute added.active
    assert activated.active

    integrations = Integrations.list_integrations(scope)
    assert Enum.count(integrations, & &1.active) == 1
    assert Enum.find(integrations, & &1.active).id == selected.id
  end

  defp connect(scope, name) do
    Integrations.connect(scope, "openai", "api_key", %{"api_key" => "#{name}-secret"},
      display_name: name
    )
  end
end
