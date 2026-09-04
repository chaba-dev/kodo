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

  defp connect_openai(scope) do
    Integrations.connect(scope, "openai", "api_key", %{"api_key" => "audit-cascade-secret"})
  end
end
