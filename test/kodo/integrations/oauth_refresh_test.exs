defmodule Kodo.Integrations.OAuthRefreshTest do
  use Kodo.DataCase, async: false

  alias Kodo.AccountsFixtures
  alias Kodo.Integrations
  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.DeviceAuthorizationAttempt
  alias Kodo.Integrations.Integration
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

  test "user deletion cascades OAuth state and fences an in-flight refresh", context do
    assert {:ok, _attempt} =
             Integrations.begin_device_authorization(
               context.scope,
               context.integration.id,
               context.integration.credential_generation,
               %{"device_auth_id" => "device", "user_code" => "CODE"},
               0
             )

    integration = Repo.reload!(context.integration)
    owner = self()

    blocked = fn _refresh_token ->
      send(owner, {:deletion_refresh_started, self()})

      receive do
        :finish_deleted_refresh -> {:ok, rotated_tokens("account")}
      end
    end

    client = fake_client([blocked])
    refresh = Task.async(fn -> refresh(%{context | integration: integration}, client) end)
    assert_receive {:deletion_refresh_started, worker}

    assert Repo.reload!(integration).refresh_claim_owner_id
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
