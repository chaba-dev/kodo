defmodule Kodo.IntegrationsConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Kodo.Accounts.Scope
  alias Kodo.AccountsFixtures
  alias Kodo.Integrations
  alias Kodo.Integrations.DeviceAuthorizationAttempt
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
        contended_task(supervisor, fn ->
          Integrations.connect(scope, "openai", "api_key", %{"api_key" => "#{name}-secret"},
            display_name: name
          )
        end)
      end)
      |> release_contenders()
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
        contended_task(supervisor, fn ->
          Integrations.activate(scope, integration.id, integration.credential_generation)
        end)
      end)
      |> release_contenders()
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

    connect_task = contended_task(supervisor, fn -> connect(scope, "added") end)

    activate_task =
      contended_task(supervisor, fn ->
        Integrations.activate(scope, selected.id, selected.credential_generation)
      end)

    [connect_task, activate_task] = release_contenders([connect_task, activate_task])

    assert {:ok, added} = Task.await(connect_task)
    assert {:ok, activated} = Task.await(activate_task)
    refute added.active
    assert activated.active

    integrations = Integrations.list_integrations(scope)
    assert Enum.count(integrations, & &1.active) == 1
    assert Enum.find(integrations, & &1.active).id == selected.id
  end

  test "simultaneous device authorization starts preserve one generation-fenced attempt", %{
    scope: scope,
    supervisor: supervisor
  } do
    integration =
      %Integration{user_id: scope.user.id}
      |> Integration.create_changeset(%{
        provider: "openai_codex",
        authentication_type: "oauth"
      })
      |> Repo.insert!()

    results =
      ["first", "second"]
      |> Enum.map(fn code ->
        contended_task(supervisor, fn ->
          Integrations.begin_device_authorization(
            scope,
            integration.id,
            0,
            %{"device_auth_id" => "#{code}-device", "user_code" => code},
            1_000
          )
        end)
      end)
      |> release_contenders()
      |> Task.await_many()

    assert Enum.count(results, &match?({:ok, %DeviceAuthorizationAttempt{}}, &1)) == 1
    assert {:error, :stale_credential_generation} in results

    assert Repo.aggregate(
             from(attempt in DeviceAuthorizationAttempt,
               where: attempt.integration_id == ^integration.id and attempt.state == "active"
             ),
             :count
           ) == 1
  end

  test "device authorization start and cancellation use one lock order without deadlocks", %{
    scope: scope,
    supervisor: supervisor
  } do
    for iteration <- 1..10 do
      integration =
        %Integration{user_id: scope.user.id}
        |> Integration.create_changeset(%{
          provider: "openai_codex",
          authentication_type: "oauth",
          display_name: "Account #{iteration}"
        })
        |> Repo.insert!()

      assert {:ok, attempt} =
               Integrations.begin_device_authorization(
                 scope,
                 integration.id,
                 0,
                 %{"device_auth_id" => "first", "user_code" => "FIRST"},
                 0
               )

      cancel =
        contended_task(supervisor, fn ->
          Integrations.cancel_device_authorization(
            scope,
            attempt.id,
            attempt.attempt_generation
          )
        end)

      start =
        contended_task(supervisor, fn ->
          Integrations.begin_device_authorization(
            scope,
            integration.id,
            1,
            %{"device_auth_id" => "second", "user_code" => "SECOND"},
            0
          )
        end)

      [cancel_result, start_result] =
        [cancel, start]
        |> release_contenders()
        |> Task.await_many()

      assert match?({:ok, %DeviceAuthorizationAttempt{}}, start_result)

      assert match?({:ok, %DeviceAuthorizationAttempt{}}, cancel_result) or
               cancel_result == {:error, :stale_device_authorization}
    end
  end

  defp connect(scope, name) do
    Integrations.connect(scope, "openai", "api_key", %{"api_key" => "#{name}-secret"},
      display_name: name
    )
  end

  defp contended_task(supervisor, operation) do
    owner = self()

    Task.Supervisor.async_nolink(supervisor, fn ->
      Repo.checkout(fn ->
        %{rows: [[backend_pid]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()")
        send(owner, {:contender_ready, self(), backend_pid})
        receive do: (:run -> operation.())
      end)
    end)
  end

  defp release_contenders(tasks) do
    contenders =
      Enum.map(tasks, fn task ->
        task_pid = task.pid
        assert_receive {:contender_ready, ^task_pid, backend_pid}
        pid = task_pid
        {pid, backend_pid}
      end)

    assert contenders |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == length(tasks)
    Enum.each(contenders, fn {pid, _backend_pid} -> send(pid, :run) end)
    tasks
  end
end
