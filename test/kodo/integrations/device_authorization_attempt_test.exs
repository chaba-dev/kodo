defmodule Kodo.Integrations.DeviceAuthorizationAttemptTest do
  use Kodo.DataCase, async: true

  alias Kodo.AccountsFixtures
  alias Kodo.Integrations.DeviceAuthorizationAttempt
  alias Kodo.Integrations.Integration

  describe "create_changeset/2" do
    test "does not cast ownership, encrypted payload, claim, or terminal state" do
      attempt = prepared_attempt(%Integration{id: Ecto.UUID.generate(), user_id: 123})

      changeset =
        DeviceAuthorizationAttempt.create_changeset(attempt, %{
          provider: "openai_codex",
          attempt_generation: 1,
          expected_integration_generation: 0,
          provider_deadline: DateTime.add(DateTime.utc_now(), 900, :second),
          polling_interval_ms: 5_000,
          next_poll_at: DateTime.utc_now(),
          user_id: 456,
          integration_id: Ecto.UUID.generate(),
          encrypted_payload: "browser supplied",
          claim_owner_id: Ecto.UUID.generate(),
          state: "completed"
        })

      refute Map.has_key?(changeset.changes, :user_id)
      refute Map.has_key?(changeset.changes, :integration_id)
      refute Map.has_key?(changeset.changes, :encrypted_payload)
      refute Map.has_key?(changeset.changes, :claim_owner_id)
      refute Map.has_key?(changeset.changes, :state)
    end

    test "redacts encrypted authorization payloads from inspection" do
      id = Ecto.UUID.generate()

      inspected =
        inspect(%DeviceAuthorizationAttempt{id: id, encrypted_payload: "ciphertext-secret"})

      refute inspected =~ "ciphertext-secret"
      refute inspected =~ "encrypted_payload"
      refute inspected =~ id
    end
  end

  describe "database constraints" do
    test "enforces one active attempt per integration and immutable generation uniqueness" do
      integration = integration_fixture()

      assert {:ok, first} = insert_attempt(integration, attempt_generation: 1)

      assert {:error, active_changeset} = insert_attempt(integration, attempt_generation: 2)
      assert "has already been taken" in errors_on(active_changeset).integration_id

      Repo.update!(
        change(first,
          state: "cancelled",
          encrypted_payload: nil,
          encryption_key_version: nil,
          payload_format_version: nil
        )
      )

      assert {:ok, _second} = insert_attempt(integration, attempt_generation: 2)

      assert {:error, generation_changeset} =
               insert_attempt(integration,
                 attempt_generation: 1,
                 state: "failed",
                 encrypted_payload: nil,
                 encryption_key_version: nil,
                 payload_format_version: nil
               )

      assert "has already been taken" in errors_on(generation_changeset).integration_id
    end

    test "rejects attempts linked to another owner" do
      integration = integration_fixture()
      another_user = AccountsFixtures.user_fixture()

      assert {:error, changeset} = insert_attempt(integration, user_id: another_user.id)
      assert "does not exist" in errors_on(changeset).integration_id
    end

    test "rejects invalid generations, intervals, and claim shapes" do
      integration = integration_fixture()

      for attrs <- [
            [attempt_generation: 0],
            [expected_integration_generation: -1],
            [polling_interval_ms: -1],
            [polling_interval_ms: 900_001],
            [claim_owner_id: Ecto.UUID.generate()],
            [
              state: "completed",
              claim_owner_id: Ecto.UUID.generate(),
              claim_lease_expires_at: now()
            ]
          ] do
        assert {:error, changeset} = insert_attempt(integration, attrs)

        assert Enum.any?(errors_on(changeset), fn {_field, messages} ->
                 "is invalid" in messages
               end)
      end

      assert {:ok, _attempt} = insert_attempt(integration, polling_interval_ms: 0)
    end

    test "requires encrypted payloads only while an attempt is active" do
      integration = integration_fixture()

      assert {:error, active_changeset} = insert_attempt(integration, encrypted_payload: nil)
      assert "is invalid" in errors_on(active_changeset).state

      assert {:error, terminal_changeset} = insert_attempt(integration, state: "cancelled")
      assert "is invalid" in errors_on(terminal_changeset).state

      assert {:ok, _terminal} =
               insert_attempt(integration,
                 state: "cancelled",
                 encrypted_payload: nil,
                 encryption_key_version: nil,
                 payload_format_version: nil
               )
    end

    test "cascades attempts when an integration is deleted" do
      integration = integration_fixture()
      assert {:ok, attempt} = insert_attempt(integration)

      Repo.delete!(integration)

      refute Repo.get(DeviceAuthorizationAttempt, attempt.id)
    end
  end

  defp integration_fixture do
    user = AccountsFixtures.user_fixture()

    %Integration{user_id: user.id}
    |> Integration.create_changeset(%{
      provider: "openai_codex",
      authentication_type: "oauth"
    })
    |> Repo.insert!()
  end

  defp insert_attempt(integration, attrs \\ []) do
    integration
    |> prepared_attempt()
    |> struct!(attrs)
    |> change()
    |> DeviceAuthorizationAttempt.constraint_changeset()
    |> Repo.insert()
  end

  defp prepared_attempt(integration) do
    %DeviceAuthorizationAttempt{
      id: Ecto.UUID.generate(),
      user_id: integration.user_id,
      integration_id: integration.id,
      provider: "openai_codex",
      attempt_generation: 1,
      expected_integration_generation: 0,
      encrypted_payload: "opaque",
      encryption_key_version: "test-v1",
      payload_format_version: 1,
      provider_deadline: DateTime.add(now(), 900, :second),
      polling_interval_ms: 5_000,
      next_poll_at: now()
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
