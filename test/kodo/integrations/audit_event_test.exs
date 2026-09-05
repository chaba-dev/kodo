defmodule Kodo.Integrations.AuditEventTest do
  use Kodo.DataCase, async: true

  alias Kodo.AccountsFixtures
  alias Kodo.Integrations
  alias Kodo.Integrations.AuditEvent

  test "records credential-free lifecycle events for only the owning user" do
    scope = AccountsFixtures.user_scope_fixture()
    other_scope = AccountsFixtures.user_scope_fixture()
    submitted_secret = "audit-must-not-retain-this-key"
    replacement_secret = "audit-must-not-retain-replacement"

    assert {:ok, integration} =
             Integrations.connect(scope, "openai", "api_key", %{"api_key" => submitted_secret})

    assert {:ok, replaced} =
             Integrations.replace_credentials(
               scope,
               integration.id,
               integration.credential_generation,
               %{"api_key" => replacement_secret}
             )

    assert {:ok, validated} =
             Integrations.validation_succeeded(
               scope,
               replaced.id,
               replaced.credential_generation
             )

    assert {:ok, _disconnected} =
             Integrations.disconnect(scope, validated.id, validated.credential_generation)

    events = Integrations.list_audit_events(scope)

    assert Enum.map(events, & &1.event_type) == [
             "api_key_submitted",
             "api_key_replaced",
             "validation_succeeded",
             "integration_disconnected"
           ]

    assert Enum.all?(events, fn event ->
             event.actor_user_id == scope.user.id and event.integration_id == integration.id and
               event.provider == "openai"
           end)

    refute inspect(events) =~ submitted_secret
    refute inspect(events) =~ replacement_secret
    assert Integrations.list_audit_events(other_scope) == []
  end

  test "rolls back audit records with account deletion" do
    scope = AccountsFixtures.user_scope_fixture()
    assert {:ok, _integration} = connect_openai(scope)
    assert Repo.aggregate(AuditEvent, :count) == 1

    Repo.delete!(scope.user)

    assert Repo.aggregate(AuditEvent, :count) == 0
  end

  test "records reconnect as a submission with the new generation" do
    scope = AccountsFixtures.user_scope_fixture()
    {:ok, integration} = connect_openai(scope)

    {:ok, disconnected} =
      Integrations.disconnect(scope, integration.id, integration.credential_generation)

    assert {:ok, _reconnected} =
             Integrations.reconnect_api_key(
               scope,
               disconnected.id,
               disconnected.credential_generation,
               %{"api_key" => "reconnected-secret"}
             )

    assert Enum.map(Integrations.list_audit_events(scope), fn event ->
             {event.event_type, event.credential_generation}
           end) == [
             {"api_key_submitted", 1},
             {"integration_disconnected", 2},
             {"api_key_submitted", 3}
           ]
  end

  test "records bounded invalid and unavailable validation outcomes" do
    scope = AccountsFixtures.user_scope_fixture()
    {:ok, integration} = connect_openai(scope)

    assert {:ok, invalid} =
             Integrations.validation_invalid(
               scope,
               integration.id,
               integration.credential_generation
             )

    assert {:ok, _unavailable} =
             Integrations.validation_unavailable(
               scope,
               invalid.id,
               invalid.credential_generation,
               "rate_limited"
             )

    assert Enum.map(Integrations.list_audit_events(scope), fn event ->
             {event.event_type, event.credential_generation}
           end) == [
             {"api_key_submitted", 1},
             {"validation_invalid", 1},
             {"validation_unavailable", 1}
           ]
  end

  test "records credential-free lifecycle events for every API-key provider" do
    scope = AccountsFixtures.user_scope_fixture()

    for provider <- ~w(openai anthropic openrouter) do
      secret = "#{provider}-audit-secret"

      assert {:ok, integration} =
               Integrations.connect(scope, provider, "api_key", %{"api_key" => secret})

      assert {:ok, replaced} =
               Integrations.replace_credentials(
                 scope,
                 integration.id,
                 integration.credential_generation,
                 %{"api_key" => "replacement-#{secret}"}
               )

      assert {:ok, valid} =
               Integrations.validation_succeeded(
                 scope,
                 replaced.id,
                 replaced.credential_generation
               )

      assert {:ok, _disconnected} =
               Integrations.disconnect(scope, valid.id, valid.credential_generation)
    end

    events = Integrations.list_audit_events(scope)

    assert Enum.frequencies_by(events, & &1.provider) == %{
             "anthropic" => 4,
             "openai" => 4,
             "openrouter" => 4
           }

    assert Enum.all?(events, &(&1.actor_user_id == scope.user.id))

    for provider <- ~w(openai anthropic openrouter) do
      refute inspect(events) =~ "#{provider}-audit-secret"
    end
  end

  defp connect_openai(scope) do
    Integrations.connect(scope, "openai", "api_key", %{"api_key" => "audit-cascade-secret"})
  end
end
