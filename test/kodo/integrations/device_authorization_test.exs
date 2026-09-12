defmodule Kodo.Integrations.DeviceAuthorizationTest do
  use Kodo.DataCase, async: false

  alias Kodo.AccountsFixtures
  alias Kodo.Integrations
  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.DeviceAuthorization
  alias Kodo.Integrations.DeviceAuthorizationAttempt
  alias Kodo.Integrations.Integration
  alias Kodo.Test.FakeDeviceAuthorizationClient

  setup do
    scope = AccountsFixtures.user_scope_fixture()

    integration =
      %Integration{user_id: scope.user.id}
      |> Integration.create_changeset(%{
        provider: "openai_codex",
        authentication_type: "oauth"
      })
      |> Repo.insert!()

    %{scope: scope, integration: integration}
  end

  test "polls until authorized, exchanges once, and installs the tokens", %{
    scope: scope,
    integration: integration
  } do
    exchange_payload = exchange_payload()
    tokens = tokens()

    client =
      fake_client(
        poll: [:pending, {:ok, exchange_payload}],
        exchange: [{:ok, tokens}]
      )

    {claim, payload} = claimed_attempt(scope, integration)

    assert :ok = DeviceAuthorization.run(scope, claim, payload, client_opts(client))

    completed = Repo.reload!(integration)
    assert completed.connection_status == "connected"
    assert completed.active
    assert completed.credential_generation == 2
    assert {:ok, credentials} = CredentialEncryption.decrypt(completed)
    assert credentials["access_token"] == tokens["access_token"]
    assert credentials["refresh_token"] == "refresh-secret"
    assert credentials["account_id"] == "account-secret"

    assert %{state: "completed", encrypted_payload: nil} = Repo.reload!(claim)

    assert calls(client) == [
             {:poll, payload},
             {:poll, payload},
             {:exchange, exchange_payload}
           ]
  end

  test "resumes a persisted authorization code directly at exchange", %{
    scope: scope,
    integration: integration
  } do
    client = fake_client(exchange: [{:ok, tokens()}])
    {claim, _payload} = claimed_attempt(scope, integration)

    assert {:ok, persisted} =
             Integrations.store_device_authorization_exchange(scope, claim, exchange_payload())

    assert {:ok, {persisted, payload}} =
             Integrations.admit_device_authorization_exchange(scope, persisted)

    assert :ok = DeviceAuthorization.run(scope, persisted, payload, client_opts(client))
    assert calls(client) == [{:exchange, exchange_payload()}]
  end

  test "terminal provider errors fail the attempt without changing credentials", %{
    scope: scope,
    integration: integration
  } do
    client = fake_client(poll: [{:error, :device_authorization_rejected}])
    {claim, payload} = claimed_attempt(scope, integration)

    assert {:error, :device_authorization_rejected} =
             DeviceAuthorization.run(scope, claim, payload, client_opts(client))

    assert %{state: "failed", terminal_error_code: "provider_rejected"} = Repo.reload!(claim)
    assert Repo.reload!(integration).connection_status == "disconnected"

    assert Enum.map(Integrations.list_audit_events(scope), & &1.event_type) == [
             "device_authorization_started",
             "device_authorization_failed"
           ]
  end

  test "a stale claimant performs no provider operation", %{
    scope: scope,
    integration: integration
  } do
    client = fake_client(poll: [{:ok, exchange_payload()}])
    {claim, payload} = claimed_attempt(scope, integration)

    Repo.update!(
      change(claim, claim_lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    )

    assert {:ok, {_takeover, _payload}} =
             Integrations.claim_device_authorization(
               scope,
               integration.id,
               Ecto.UUID.generate()
             )

    assert {:error, :stale_device_authorization_claim} =
             DeviceAuthorization.run(scope, claim, payload, client_opts(client))

    assert calls(client) == []
  end

  test "a healthy claim cannot be replaced by another task using the same node owner", %{
    scope: scope,
    integration: integration
  } do
    owner = Ecto.UUID.generate()

    assert {:ok, _attempt} =
             Integrations.begin_device_authorization(
               scope,
               integration.id,
               integration.credential_generation,
               %{"device_auth_id" => "device", "user_code" => "CODE"},
               0
             )

    assert {:ok, {claim, _payload}} =
             Integrations.claim_device_authorization(scope, integration.id, owner)

    assert {:error, :device_authorization_not_claimable} =
             Integrations.claim_device_authorization(scope, integration.id, owner)

    assert Repo.reload!(claim).claim_epoch == claim.claim_epoch
  end

  test "a poll admitted before takeover may finish but cannot persist its result", %{
    scope: scope,
    integration: integration
  } do
    owner = self()

    blocking_poll = fn :poll, _payload ->
      send(owner, {:poll_admitted, self()})

      receive do
        :finish_poll -> {:ok, exchange_payload()}
      end
    end

    client = fake_client(poll: [blocking_poll])
    {claim, payload} = claimed_attempt(scope, integration)
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        DeviceAuthorization.run(scope, claim, payload, client_opts(client))
      end)

    assert_receive {:poll_admitted, poller}

    Repo.update!(
      change(claim, claim_lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    )

    assert {:ok, {takeover, ^payload}} =
             Integrations.claim_device_authorization(
               scope,
               integration.id,
               Ecto.UUID.generate()
             )

    send(poller, :finish_poll)

    assert {:error, :stale_device_authorization_claim} = Task.await(task)
    assert Repo.reload!(takeover).state == "active"
    assert Repo.reload!(integration).connection_status == "disconnected"
    assert calls(client) == [{:poll, payload}]
  end

  test "waits a full provider interval after a pending response", %{
    scope: scope,
    integration: integration
  } do
    owner = self()

    blocking_poll = fn :poll, _payload ->
      send(owner, {:pending_poll_started, self()})

      receive do
        :finish_pending -> :pending
      end
    end

    second_poll = fn :poll, _payload ->
      send(owner, :second_poll_started)
      {:error, :device_authorization_rejected}
    end

    client = fake_client(poll: [blocking_poll, second_poll])

    assert {:ok, _attempt} =
             Integrations.begin_device_authorization(
               scope,
               integration.id,
               integration.credential_generation,
               %{"device_auth_id" => "device", "user_code" => "CODE"},
               100
             )

    assert {:ok, {claim, payload}} =
             Integrations.claim_device_authorization(
               scope,
               integration.id,
               Ecto.UUID.generate()
             )

    Repo.update!(change(claim, next_poll_at: DateTime.add(DateTime.utc_now(), -1, :second)))
    claim = Repo.reload!(claim)
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        DeviceAuthorization.run(scope, claim, payload, client_opts(client))
      end)

    assert_receive {:pending_poll_started, poller}
    send(poller, :finish_pending)
    refute_receive :second_poll_started, 50
    assert_receive :second_poll_started, 200
    assert {:error, :device_authorization_rejected} = Task.await(task)
  end

  test "begin persists the provider response and launches a supervised finite task", %{
    scope: scope,
    integration: integration
  } do
    supervisor = start_supervised!(Task.Supervisor)

    client =
      fake_client(
        create: [
          {:ok,
           %{
             payload: %{"device_auth_id" => "device", "user_code" => "CODE"},
             polling_interval_ms: 0,
             verification_url: "https://auth.openai.com/codex/device"
           }}
        ],
        poll: [{:error, :device_authorization_rejected}]
      )

    assert {:ok, started} =
             DeviceAuthorization.begin(
               scope,
               integration.id,
               integration.credential_generation,
               client_opts(client, supervisor: supervisor, claim_owner_id: Ecto.UUID.generate())
             )

    assert started.verification_url == "https://auth.openai.com/codex/device"
    assert %Task{} = started.task
    assert {:error, :device_authorization_rejected} = Task.await(started.task)
    assert Repo.reload!(started.attempt).state == "failed"
  end

  test "begin rejects a client-selected verification destination before persistence", %{
    scope: scope,
    integration: integration
  } do
    client =
      fake_client(
        create: [
          {:ok,
           %{
             payload: %{"device_auth_id" => "device", "user_code" => "CODE"},
             polling_interval_ms: 0,
             verification_url: "https://attacker.example/device"
           }}
        ]
      )

    assert {:error, :device_authorization_response_invalid} =
             DeviceAuthorization.begin(
               scope,
               integration.id,
               integration.credential_generation,
               client_opts(client)
             )

    refute Repo.exists?(DeviceAuthorizationAttempt)
  end

  defp claimed_attempt(scope, integration) do
    assert {:ok, _attempt} =
             Integrations.begin_device_authorization(
               scope,
               integration.id,
               integration.credential_generation,
               %{"device_auth_id" => "device", "user_code" => "CODE"},
               0
             )

    assert {:ok, claimed} =
             Integrations.claim_device_authorization(
               scope,
               integration.id,
               Ecto.UUID.generate()
             )

    claimed
  end

  defp fake_client(responses) do
    defaults = %{create: [], poll: [], exchange: []}

    start_supervised!(
      {Agent, fn -> %{responses: Map.merge(defaults, Map.new(responses)), calls: []} end},
      id: {:fake_device_client, System.unique_integer([:positive])}
    )
  end

  defp client_opts(agent, opts \\ []) do
    [client: FakeDeviceAuthorizationClient, client_options: [agent: agent]] ++ opts
  end

  defp calls(agent) do
    agent
    |> Agent.get(& &1.calls)
    |> Enum.reverse()
  end

  defp exchange_payload do
    %{
      "authorization_code" => "authorization-secret",
      "code_challenge" => "challenge-secret",
      "code_verifier" => "verifier-secret"
    }
  end

  defp tokens do
    now = DateTime.utc_now()

    %{
      "access_token" => jwt(%{"exp" => DateTime.to_unix(now) + 3_600}),
      "refresh_token" => "refresh-secret",
      "id_token" =>
        jwt(%{
          "https://api.openai.com/auth" => %{"chatgpt_account_id" => "account-secret"}
        })
    }
  end

  defp jwt(claims) do
    encoded = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    "header.#{encoded}.signature"
  end
end
