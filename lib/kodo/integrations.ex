defmodule Kodo.Integrations do
  @moduledoc "Owns scoped provider-integration credential lifecycle transitions."

  import Ecto.Changeset
  import Ecto.Query

  alias Kodo.Accounts.Scope
  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.Integration
  alias Kodo.Repo

  @safe_validation_errors ~w(network_error timeout tls_error provider_unavailable rate_limited)

  def list_integrations(%Scope{user: user}) do
    Integration
    |> where([integration], integration.user_id == ^user.id)
    |> order_by([integration], asc: integration.provider)
    |> Repo.all()
  end

  def get_integration(%Scope{user: user}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Integration{} = integration <- Repo.get_by(Integration, id: id, user_id: user.id) do
      {:ok, integration}
    else
      _missing -> {:error, :integration_not_found}
    end
  end

  def get_integration_by_provider(%Scope{user: user}, provider) do
    case Repo.get_by(Integration, user_id: user.id, provider: provider) do
      %Integration{} = integration -> {:ok, integration}
      nil -> {:error, :integration_not_found}
    end
  end

  def connect(scope, provider, authentication_type, credentials, opts \\ [])

  def connect(%Scope{user: user}, provider, "api_key", credentials, opts) do
    integration = %Integration{id: Ecto.UUID.generate(), user_id: user.id}

    changeset =
      Integration.create_changeset(integration, %{
        provider: provider,
        authentication_type: "api_key"
      })

    with true <- changeset.valid?,
         {:ok, encrypted} <- CredentialEncryption.encrypt(apply_changes(changeset), credentials) do
      changeset
      |> change(
        Map.merge(encrypted, %{
          connection_status: "connected",
          validation_status: "unverified",
          credential_generation: 1,
          expires_at: opts[:expires_at]
        })
      )
      |> Integration.constraint_changeset()
      |> Repo.insert()
      |> normalize_insert_result()
    else
      false -> {:error, changeset}
      {:error, _reason} = error -> error
    end
  end

  def connect(%Scope{}, _provider, _authentication_type, _credentials, _opts),
    do: {:error, :authentication_type_mismatch}

  def replace_credentials(%Scope{} = scope, id, generation, credentials, opts \\ []) do
    install_credentials(
      scope,
      id,
      generation,
      credentials,
      opts,
      Integration.connection_statuses(),
      "api_key"
    )
  end

  def oauth_succeeded(%Scope{} = scope, id, generation, credentials, opts \\ []) do
    install_credentials(
      scope,
      id,
      generation,
      credentials,
      opts,
      Integration.connection_statuses(),
      "oauth"
    )
  end

  def refresh_succeeded(%Scope{} = scope, id, generation, credentials, opts \\ []) do
    install_credentials(
      scope,
      id,
      generation,
      credentials,
      opts,
      ~w(connected reauthorization_required),
      "oauth"
    )
  end

  def validation_succeeded(%Scope{} = scope, id, generation) do
    update_fenced(scope, id, generation, ["connected"], %{
      validation_status: "valid",
      validated_at: now(),
      validation_error_code: nil
    })
  end

  def validation_invalid(%Scope{} = scope, id, generation) do
    update_fenced(scope, id, generation, ["connected"], %{
      validation_status: "invalid",
      validated_at: now(),
      validation_error_code: "invalid_credentials"
    })
  end

  def validation_unavailable(%Scope{} = scope, id, generation, error_code)
      when error_code in @safe_validation_errors do
    update_fenced(scope, id, generation, ["connected"], %{
      validation_status: "unavailable",
      validated_at: now(),
      validation_error_code: error_code
    })
  end

  def validation_unavailable(%Scope{}, _id, _generation, _error_code),
    do: {:error, :unsafe_validation_error}

  def refresh_invalid_grant(%Scope{} = scope, id, generation) do
    with {:ok, integration} <- get_integration(scope, id),
         true <- integration.authentication_type == "oauth" do
      update_fenced(scope, id, generation, ["connected"], %{
        connection_status: "reauthorization_required",
        validation_status: "unverified",
        validated_at: nil,
        validation_error_code: nil
      })
    else
      false -> {:error, :authentication_type_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def disconnect(%Scope{} = scope, id, generation) do
    update_fenced(scope, id, generation, Integration.connection_statuses(), %{
      connection_status: "disconnected",
      validation_status: "unverified",
      encrypted_credentials: nil,
      encryption_key_version: nil,
      credential_format_version: nil,
      credential_generation: generation + 1,
      expires_at: nil,
      validated_at: nil,
      refreshed_at: nil,
      validation_error_code: nil
    })
  end

  def safe_validation_errors, do: @safe_validation_errors

  defp install_credentials(
         scope,
         id,
         generation,
         credentials,
         opts,
         allowed_connections,
         authentication_type
       ) do
    with {:ok, integration} <- get_integration(scope, id),
         :ok <- require_generation(integration, generation),
         :ok <- require_authentication_type(integration, authentication_type),
         {:ok, encrypted} <- CredentialEncryption.encrypt(integration, credentials) do
      changes =
        Map.merge(encrypted, %{
          connection_status: "connected",
          validation_status: "unverified",
          credential_generation: generation + 1,
          expires_at: opts[:expires_at],
          validated_at: nil,
          refreshed_at: opts[:refreshed_at],
          validation_error_code: nil
        })

      update_fenced(scope, id, generation, allowed_connections, changes)
    else
      {:error, _reason} = error -> error
    end
  end

  defp require_generation(%Integration{credential_generation: generation}, generation), do: :ok
  defp require_generation(%Integration{}, _generation), do: {:error, :stale_credential_generation}

  defp require_authentication_type(%Integration{authentication_type: type}, type), do: :ok

  defp require_authentication_type(%Integration{}, _type),
    do: {:error, :authentication_type_mismatch}

  defp update_fenced(%Scope{user: user}, id, generation, allowed_connections, changes)
       when is_integer(generation) and generation >= 0 do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Repo.transaction(fn ->
          execute_fenced_update(user.id, id, generation, allowed_connections, changes)
        end)

      :error ->
        {:error, :stale_credential_generation}
    end
  end

  defp update_fenced(%Scope{}, _id, _generation, _allowed_connections, _changes),
    do: {:error, :stale_credential_generation}

  defp execute_fenced_update(user_id, id, generation, allowed_connections, changes) do
    query =
      from integration in Integration,
        where:
          integration.id == ^id and integration.user_id == ^user_id and
            integration.credential_generation == ^generation and
            integration.connection_status in ^allowed_connections

    case Repo.update_all(query, set: Map.to_list(Map.put(changes, :updated_at, now()))) do
      {1, nil} -> Repo.get_by!(Integration, id: id, user_id: user_id)
      {0, nil} -> Repo.rollback(:stale_credential_generation)
    end
  end

  defp normalize_insert_result({:error, changeset} = error) do
    cond do
      constraint_error?(changeset, :foreign) -> {:error, :integration_owner_not_found}
      constraint_error?(changeset, :unique) -> {:error, :integration_already_exists}
      true -> error
    end
  end

  defp normalize_insert_result(result), do: result

  defp constraint_error?(changeset, type) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      metadata[:constraint] == type
    end)
  end

  defp now, do: DateTime.utc_now()
end
