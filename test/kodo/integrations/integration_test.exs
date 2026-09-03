defmodule Kodo.Integrations.IntegrationTest do
  use Kodo.DataCase, async: true

  alias Kodo.AccountsFixtures
  alias Kodo.Integrations.Integration

  describe "create_changeset/2" do
    test "accepts supported provider authentication pairs" do
      for {provider, authentication_type} <- [
            {"openai", "api_key"},
            {"openai_codex", "oauth"},
            {"anthropic", "api_key"},
            {"openrouter", "api_key"}
          ] do
        assert Integration.create_changeset(%Integration{}, %{
                 provider: provider,
                 authentication_type: authentication_type
               }).valid?
      end
    end

    test "does not cast ownership or credential fields" do
      changeset =
        Integration.create_changeset(%Integration{}, %{
          provider: "openai",
          authentication_type: "api_key",
          user_id: 123,
          encrypted_credentials: "browser supplied"
        })

      refute Map.has_key?(changeset.changes, :user_id)
      refute Map.has_key?(changeset.changes, :encrypted_credentials)
    end

    test "redacts encrypted credentials from inspection" do
      inspected = inspect(%Integration{encrypted_credentials: "ciphertext-secret"})

      refute inspected =~ "ciphertext-secret"
      refute inspected =~ "encrypted_credentials"
    end
  end

  describe "database constraints" do
    test "accept every allowed connection and validation state" do
      allowed_states = [
        {"disconnected", "unverified", false},
        {"connected", "unverified", true},
        {"connected", "valid", true},
        {"connected", "invalid", true},
        {"connected", "unavailable", true},
        {"reauthorization_required", "unverified", true}
      ]

      for {connection, validation, payload?} <- allowed_states do
        assert {:ok, _integration} = insert_state(connection, validation, payload?)
      end
    end

    test "rejects impossible connection and validation pairs" do
      invalid_states =
        for connection <- Integration.connection_statuses(),
            validation <- Integration.validation_statuses(),
            {connection, validation} not in [
              {"disconnected", "unverified"},
              {"connected", "unverified"},
              {"connected", "valid"},
              {"connected", "invalid"},
              {"connected", "unavailable"},
              {"reauthorization_required", "unverified"}
            ],
            do: {connection, validation}

      for {connection, validation} <- invalid_states do
        assert {:error, changeset} = insert_state(connection, validation, true)
        assert "is invalid" in errors_on(changeset).connection_status
      end
    end

    test "requires a complete encrypted payload only for non-disconnected states" do
      assert {:error, disconnected} = insert_state("disconnected", "unverified", true)
      assert "is invalid" in errors_on(disconnected).connection_status

      assert {:error, connected} = insert_state("connected", "unverified", false)
      assert "is invalid" in errors_on(connected).connection_status

      assert {:error, reauthorization} =
               insert_state("reauthorization_required", "unverified", false)

      assert "is invalid" in errors_on(reauthorization).connection_status
    end

    test "rejects unsupported provider authentication pairs and generations" do
      user = AccountsFixtures.user_fixture()

      invalid_pair = %Integration{
        user_id: user.id,
        provider: "openai",
        authentication_type: "oauth"
      }

      assert {:error, pair_changeset} = insert_integration(invalid_pair)
      assert "is invalid" in errors_on(pair_changeset).authentication_type

      invalid_generation = %Integration{
        user_id: user.id,
        provider: "openai",
        authentication_type: "api_key",
        credential_generation: -1
      }

      assert {:error, generation_changeset} = insert_integration(invalid_generation)
      assert "is invalid" in errors_on(generation_changeset).credential_generation
    end

    test "enforces one integration per user and provider" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, _integration} = insert_disconnected(user, "openai", "api_key")
      assert {:error, changeset} = insert_disconnected(user, "openai", "api_key")
      assert "has already been taken" in errors_on(changeset).user_id
    end

    test "cascades integration deletion when its user is deleted" do
      user = AccountsFixtures.user_fixture()
      assert {:ok, integration} = insert_disconnected(user, "openai", "api_key")

      Repo.delete!(user)

      refute Repo.get(Integration, integration.id)
    end
  end

  defp insert_state(connection, validation, payload?) do
    user = AccountsFixtures.user_fixture()

    %Integration{
      user_id: user.id,
      provider: "openai",
      authentication_type: "api_key",
      connection_status: connection,
      validation_status: validation
    }
    |> with_payload(payload?)
    |> insert_integration()
  end

  defp insert_disconnected(user, provider, authentication_type) do
    %Integration{user_id: user.id}
    |> Integration.create_changeset(%{
      provider: provider,
      authentication_type: authentication_type
    })
    |> Repo.insert()
  end

  defp with_payload(integration, false), do: integration

  defp with_payload(integration, true) do
    %{
      integration
      | encrypted_credentials: "ciphertext",
        encryption_key_version: "test-v1",
        credential_format_version: 1
    }
  end

  defp insert_integration(integration) do
    integration
    |> change()
    |> Integration.constraint_changeset()
    |> Repo.insert()
  end
end
