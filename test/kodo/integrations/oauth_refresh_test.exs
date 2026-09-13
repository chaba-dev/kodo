defmodule Kodo.Integrations.OAuthRefreshTest do
  use Kodo.DataCase, async: false

  alias Kodo.AccountsFixtures
  alias Kodo.Integrations
  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.DeviceAuthorizationAttempt
  alias Kodo.Integrations.DeviceAuthorizationEncryption
  alias Kodo.Integrations.Integration
  alias Kodo.Integrations.OAuthAccessValidation
  alias Kodo.Integrations.OAuthRefresh
  alias Kodo.Test.FakeRefreshClient

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: nil})
    scope = AccountsFixtures.user_scope_fixture()

    integration =
      %Integration{user_id: scope.user.id}
      |> Integration.create_changeset(%{
        provider: "openai_codex",
        authentication_type: "oauth",
        display_name: "Subscription"
      })
      |> Repo.insert!()

    current = current_tokens()

    assert {:ok, connected} =
             Integrations.oauth_succeeded(scope, integration.id, 0, current,
               expires_at: DateTime.add(DateTime.utc_now(), 30, :second)
             )

    %{scope: scope, integration: connected, supervisor: supervisor}
  end

  test "refreshes shortly before expiry and persists rotated token state", context do
    client = fake_client([{:ok, rotated_tokens("account")}])

    assert {:ok, refreshed} = refresh(context, client)
    assert refreshed.credential_generation == context.integration.credential_generation + 1
    assert refreshed.connection_status == "connected"
    assert %DateTime{} = refreshed.refreshed_at
    assert %DateTime{} = refreshed.expires_at
    assert is_nil(refreshed.refresh_claim_owner_id)

    assert {:ok, credentials} = CredentialEncryption.decrypt(refreshed)
    assert credentials["access_token"] == rotated_tokens("account")["access_token"]
    assert credentials["refresh_token"] == "rotated-refresh"
    assert credentials["account_id"] == "account"
    assert Agent.get(client, &Enum.reverse(&1.refresh_tokens)) == ["old-refresh"]
  end

  test "does not refresh a token outside the refresh buffer", context do
    integration =
      context.integration
      |> change(expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second))
      |> Repo.update!()

    client = fake_client([])

    assert {:ok, unchanged} =
             OAuthRefresh.ensure_fresh(context.scope, integration,
               client: FakeRefreshClient,
               client_options: [agent: client],
               supervisor: context.supervisor,
               claim_owner_id: Ecto.UUID.generate()
             )

    assert unchanged.credential_generation == integration.credential_generation
    assert Agent.get(client, & &1.refresh_tokens) == []
  end

  test "access validation forces a refresh and records a valid outcome", context do
    client = fake_client([{:ok, rotated_tokens("account")}])

    assert {:ok, validated} =
             OAuthAccessValidation.validate(
               context.scope,
               context.integration.id,
               context.integration.credential_generation,
               client: FakeRefreshClient,
               client_options: [agent: client],
               supervisor: context.supervisor,
               claim_owner_id: Ecto.UUID.generate()
             )

    assert validated.validation_status == "valid"
    assert validated.credential_generation == context.integration.credential_generation + 1
  end

  test "invalid grant and account changes require reauthorization without erasing credentials",
       context do
    for {response, error_code} <- [
          {{:error, :invalid_grant}, "refresh_invalid_grant"},
          {{:ok, rotated_tokens("other-account")}, "refresh_account_identity_mismatch"}
        ] do
      integration = Repo.reload!(context.integration)
      client = fake_client([response])

      assert {:error, :integration_reauthorization_required} =
               refresh(%{context | integration: integration}, client)

      required = Repo.reload!(integration)
      assert required.connection_status == "reauthorization_required"
      assert required.validation_error_code == error_code
      assert required.credential_generation == integration.credential_generation
      assert required.encrypted_credentials == integration.encrypted_credentials

      Repo.update!(
        change(required,
          connection_status: "connected",
          active: true,
          validation_error_code: nil
        )
      )
    end
  end

  test "transient provider failures preserve credentials and release the exact claim", context do
    client = fake_client([{:error, :provider_unavailable}])

    assert {:error, :provider_unavailable} = refresh(context, client)

    unchanged = Repo.reload!(context.integration)
    assert unchanged.connection_status == "connected"
    assert unchanged.encrypted_credentials == context.integration.encrypted_credentials
    assert is_nil(unchanged.refresh_claim_owner_id)
    assert unchanged.refresh_claim_epoch == 1
    assert List.last(Integrations.list_audit_events(context.scope)).event_type == "refresh_failed"
  end

  test "the first generation-matching success wins after lease takeover", context do
    owner = self()
    first_tokens = rotated_tokens("account", "first")
    second_tokens = rotated_tokens("account", "second")

    first_response = fn _refresh_token ->
      send(owner, {:first_refresh_started, self()})

      receive do
        :finish_first_refresh -> {:ok, first_tokens}
      end
    end

    client = fake_client([first_response, {:ok, second_tokens}])

    first = Task.async(fn -> refresh(context, client) end)
    assert_receive {:first_refresh_started, first_worker}

    context.integration
    |> Repo.reload!()
    |> change(refresh_lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:ok, winner} = refresh(context, client)
    assert winner.credential_generation == context.integration.credential_generation + 1

    send(first_worker, :finish_first_refresh)
    assert {:ok, same_winner} = Task.await(first)
    assert same_winner.credential_generation == winner.credential_generation

    assert {:ok, persisted} = CredentialEncryption.decrypt(Repo.reload!(winner))
    assert persisted["refresh_token"] == "second-refresh"
    assert persisted["access_token"] == second_tokens["access_token"]
  end

  test "a delayed success restores its active selection after provisional invalid grant",
       context do
    owner = self()

    first_response = fn _refresh_token ->
      send(owner, {:successful_refresh_started, self()})

      receive do
        :finish_successful_refresh -> {:ok, rotated_tokens("account", "recovered")}
      end
    end

    client = fake_client([first_response, {:error, :invalid_grant}])
    first = Task.async(fn -> refresh(context, client) end)
    assert_receive {:successful_refresh_started, first_worker}

    context.integration
    |> Repo.reload!()
    |> change(refresh_lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :integration_reauthorization_required} = refresh(context, client)
    refute Repo.reload!(context.integration).active

    send(first_worker, :finish_successful_refresh)
    assert {:ok, recovered} = Task.await(first)
    assert recovered.active

    assert {:ok, active} =
             Integrations.get_active_integration_by_provider(context.scope, "openai_codex")

    assert active.id == context.integration.id
  end

  test "a delayed success does not replace a newer explicit active selection", context do
    owner = self()

    first_response = fn _refresh_token ->
      send(owner, {:selectable_refresh_started, self()})

      receive do
        :finish_selectable_refresh -> {:ok, rotated_tokens("account", "late")}
      end
    end

    client = fake_client([first_response, {:error, :invalid_grant}])
    first = Task.async(fn -> refresh(context, client) end)
    assert_receive {:selectable_refresh_started, first_worker}

    context.integration
    |> Repo.reload!()
    |> change(refresh_lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :integration_reauthorization_required} = refresh(context, client)

    sibling = oauth_integration(context.scope, "Second subscription")

    assert {:ok, sibling} =
             Integrations.oauth_succeeded(context.scope, sibling.id, 0, current_tokens(),
               expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
             )

    assert {:ok, sibling} =
             Integrations.activate(
               context.scope,
               sibling.id,
               sibling.credential_generation
             )

    assert {:ok, _disconnected} =
             Integrations.disconnect(
               context.scope,
               sibling.id,
               sibling.credential_generation
             )

    send(first_worker, :finish_selectable_refresh)
    assert {:ok, recovered} = Task.await(first)
    refute recovered.active

    assert {:error, :integration_not_found} =
             Integrations.get_active_integration_by_provider(context.scope, "openai_codex")
  end

  test "an ordinary delayed refresh does not undo a later decision to leave no active account",
       context do
    owner = self()

    response = fn _refresh_token ->
      send(owner, {:ordinary_refresh_started, self()})

      receive do
        :finish_ordinary_refresh -> {:ok, rotated_tokens("account", "late")}
      end
    end

    client = fake_client([response])
    refresh = Task.async(fn -> refresh(context, client) end)
    assert_receive {:ordinary_refresh_started, worker}

    sibling = oauth_integration(context.scope, "Temporary selection")

    assert {:ok, sibling} =
             Integrations.oauth_succeeded(context.scope, sibling.id, 0, current_tokens(),
               expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
             )

    assert {:ok, sibling} =
             Integrations.activate(context.scope, sibling.id, sibling.credential_generation)

    assert {:ok, _disconnected} =
             Integrations.disconnect(context.scope, sibling.id, sibling.credential_generation)

    send(worker, :finish_ordinary_refresh)
    assert {:ok, recovered} = Task.await(refresh)
    refute recovered.active

    assert {:error, :integration_not_found} =
             Integrations.get_active_integration_by_provider(context.scope, "openai_codex")
  end

  test "persists a rotated response that expires during a worker pause and refreshes it again",
       context do
    admitted_at = DateTime.add(DateTime.utc_now(), -2, :second)

    expired_rotation =
      rotated_tokens("account", "short")
      |> put_in(
        ["access_token"],
        jwt(%{"exp" => DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(1)})
      )

    client = fake_client([{:ok, expired_rotation}, {:ok, rotated_tokens("account", "usable")}])

    assert {:ok, refreshed} =
             OAuthRefresh.ensure_fresh(context.scope, context.integration,
               force: true,
               now: admitted_at,
               client: FakeRefreshClient,
               client_options: [agent: client],
               supervisor: context.supervisor,
               claim_owner_id: Ecto.UUID.generate()
             )

    assert refreshed.credential_generation == context.integration.credential_generation + 2
    assert Agent.get(client, &Enum.reverse(&1.refresh_tokens)) == ["old-refresh", "short-refresh"]

    assert {:ok, credentials} = CredentialEncryption.decrypt(refreshed)
    assert credentials["refresh_token"] == "usable-refresh"
  end

  test "bounds automatic recovery when refreshed access is already expired", context do
    admitted_at = DateTime.add(DateTime.utc_now(), -10, :second)

    expired =
      rotated_tokens("account", "expired")
      |> put_in(
        ["access_token"],
        jwt(%{"exp" => DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(1)})
      )

    client = fake_client([{:ok, expired}, {:ok, expired}])

    assert {:error, :provider_unavailable} =
             OAuthRefresh.ensure_fresh(context.scope, context.integration,
               force: true,
               now: admitted_at,
               client: FakeRefreshClient,
               client_options: [agent: client],
               supervisor: context.supervisor,
               claim_owner_id: Ecto.UUID.generate()
             )

    _ = :sys.get_state(client)
    assert length(Agent.get(client, & &1.refresh_tokens)) == 2
  end

  test "persists a rotated response after its caller stops waiting", context do
    owner = self()

    blocked = fn _refresh_token ->
      send(owner, {:rotated_response_ready, self()})

      receive do
        :persist_rotated_response -> {:ok, rotated_tokens("account", "detached")}
      end
    end

    client = fake_client([blocked])

    caller =
      Task.async(fn ->
        OAuthRefresh.ensure_fresh(context.scope, context.integration,
          client: FakeRefreshClient,
          client_options: [agent: client],
          supervisor: context.supervisor,
          claim_owner_id: Ecto.UUID.generate(),
          wait_timeout: 1
        )
      end)

    assert_receive {:rotated_response_ready, worker}
    worker_ref = Process.monitor(worker)
    assert {:error, :provider_unavailable} = Task.await(caller)
    send(worker, :persist_rotated_response)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}

    refreshed = Repo.reload!(context.integration)
    assert refreshed.refresh_source_generation == context.integration.credential_generation
    assert refreshed.credential_generation == context.integration.credential_generation + 1
    assert {:ok, credentials} = CredentialEncryption.decrypt(refreshed)
    assert credentials["refresh_token"] == "detached-refresh"
  end

  test "an active reauthorization attempt blocks refresh without using its credential", context do
    assert {:ok, _attempt} =
             Integrations.begin_device_authorization(
               context.scope,
               context.integration.id,
               context.integration.credential_generation,
               %{"device_auth_id" => "device", "user_code" => "CODE"},
               0
             )

    reauthorizing = Repo.reload!(context.integration)
    client = fake_client([])

    assert {:error, :integration_reauthorization_required} =
             OAuthRefresh.ensure_fresh(context.scope, reauthorizing,
               force: true,
               client: FakeRefreshClient,
               client_options: [agent: client],
               supervisor: context.supervisor,
               claim_owner_id: Ecto.UUID.generate()
             )

    assert Agent.get(client, & &1.refresh_tokens) == []

    assert Repo.reload!(reauthorizing).credential_generation ==
             reauthorizing.credential_generation
  end

  test "an expired abandoned authorization attempt is terminalized before refresh", context do
    assert {:ok, attempt} =
             Integrations.begin_device_authorization(
               context.scope,
               context.integration.id,
               context.integration.credential_generation,
               %{"device_auth_id" => "abandoned", "user_code" => "OLD"},
               0
             )

    Repo.update!(
      change(attempt, provider_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    )

    reauthorizing = Repo.reload!(context.integration)
    client = fake_client([{:ok, rotated_tokens("account")}])

    assert {:ok, _refreshed} =
             OAuthRefresh.ensure_fresh(context.scope, reauthorizing,
               force: true,
               client: FakeRefreshClient,
               client_options: [agent: client],
               supervisor: context.supervisor,
               claim_owner_id: Ecto.UUID.generate()
             )

    assert %{state: "expired", encrypted_payload: nil} = Repo.reload!(attempt)
    assert Agent.get(client, &Enum.reverse(&1.refresh_tokens)) == ["old-refresh"]
  end

  test "an attempt expiring after refresh claim does not veto admission", context do
    owner_id = Ecto.UUID.generate()

    assert {:ok, claim} =
             Integrations.claim_refresh(
               context.scope,
               context.integration.id,
               context.integration.credential_generation,
               owner_id
             )

    insert_device_attempt(context, DateTime.add(DateTime.utc_now(), -1, :second))

    assert {:ok, admitted} = Integrations.admit_refresh_claim(context.scope, claim)
    assert admitted.refresh_claim_owner_id == owner_id
    assert :ok = Integrations.release_refresh_claim(context.scope, claim)
  end

  test "a pre-network admission failure can release its exact refresh claim", context do
    owner_id = Ecto.UUID.generate()

    assert {:ok, claim} =
             Integrations.claim_refresh(
               context.scope,
               context.integration.id,
               context.integration.credential_generation,
               owner_id
             )

    insert_device_attempt(context, DateTime.add(DateTime.utc_now(), 60, :second))

    assert {:error, :stale_refresh_claim} =
             Integrations.admit_refresh_claim(context.scope, claim)

    assert :ok = Integrations.release_refresh_claim(context.scope, claim)
    assert is_nil(Repo.reload!(context.integration).refresh_claim_owner_id)
  end

  test "user deletion cascades OAuth state and fences an in-flight refresh", context do
    owner = self()

    blocked = fn _refresh_token ->
      send(owner, {:deletion_refresh_started, self()})

      receive do
        :finish_deleted_refresh -> {:ok, rotated_tokens("account")}
      end
    end

    client = fake_client([blocked])
    refresh = Task.async(fn -> refresh(context, client) end)
    assert_receive {:deletion_refresh_started, worker}

    assert Repo.reload!(context.integration).refresh_claim_owner_id

    assert {:ok, _attempt} =
             Integrations.begin_device_authorization(
               context.scope,
               context.integration.id,
               context.integration.credential_generation,
               %{"device_auth_id" => "device", "user_code" => "CODE"},
               0
             )

    Repo.delete!(context.scope.user)
    refute Repo.exists?(Integration)
    refute Repo.exists?(DeviceAuthorizationAttempt)

    send(worker, :finish_deleted_refresh)
    assert {:error, :provider_unavailable} = Task.await(refresh)
    refute Repo.exists?(Integration)
    refute Repo.exists?(DeviceAuthorizationAttempt)
  end

  defp refresh(context, client) do
    OAuthRefresh.ensure_fresh(context.scope, context.integration,
      client: FakeRefreshClient,
      client_options: [agent: client],
      supervisor: context.supervisor,
      claim_owner_id: Ecto.UUID.generate()
    )
  end

  defp fake_client(responses) do
    start_supervised!(
      {Agent, fn -> %{responses: responses, refresh_tokens: []} end},
      id: {:fake_refresh_client, System.unique_integer([:positive])}
    )
  end

  defp oauth_integration(scope, display_name) do
    %Integration{user_id: scope.user.id}
    |> Integration.create_changeset(%{
      provider: "openai_codex",
      authentication_type: "oauth",
      display_name: display_name
    })
    |> Repo.insert!()
  end

  defp insert_device_attempt(context, deadline) do
    timestamp = DateTime.utc_now()

    attempt = %DeviceAuthorizationAttempt{
      id: Ecto.UUID.generate(),
      user_id: context.scope.user.id,
      integration_id: context.integration.id,
      provider: "openai_codex",
      attempt_generation: 1,
      expected_integration_generation: context.integration.credential_generation,
      activate_on_completion: false
    }

    assert {:ok, encrypted} =
             DeviceAuthorizationEncryption.encrypt(attempt, %{
               "device_auth_id" => "device",
               "user_code" => "CODE"
             })

    attempt
    |> Map.merge(encrypted)
    |> DeviceAuthorizationAttempt.create_changeset(%{
      provider: "openai_codex",
      attempt_generation: 1,
      expected_integration_generation: context.integration.credential_generation,
      activate_on_completion: false,
      provider_deadline: deadline,
      polling_interval_ms: 0,
      next_poll_at: timestamp
    })
    |> Repo.insert!()
  end

  defp current_tokens do
    %{
      "access_token" => "old-access",
      "refresh_token" => "old-refresh",
      "id_token" => id_token("account"),
      "account_id" => "account"
    }
  end

  defp rotated_tokens(account_id) do
    rotated_tokens(account_id, "rotated")
  end

  defp rotated_tokens(account_id, label) do
    %{
      "access_token" =>
        jwt(%{
          "exp" => DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3_600),
          "label" => label
        }),
      "refresh_token" => "#{label}-refresh",
      "id_token" => id_token(account_id)
    }
  end

  defp id_token(account_id) do
    jwt(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}})
  end

  defp jwt(claims) do
    encoded = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    "header.#{encoded}.signature"
  end
end
