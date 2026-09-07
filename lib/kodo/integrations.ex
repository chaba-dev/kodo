defmodule Kodo.Integrations do
  @moduledoc "Owns scoped provider-integration credential lifecycle transitions."

  import Ecto.Changeset
  import Ecto.Query

  alias Kodo.Accounts.Scope
  alias Kodo.Integrations.AuditEvent
  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.Integration
  alias Kodo.Repo

  @safe_validation_errors ~w(
    network_error
    timeout
    tls_error
    provider_unavailable
    rate_limited
    workspace_selection_required
  )

  def list_integrations(%Scope{user: user}) do
    Integration
    |> where([integration], integration.user_id == ^user.id)
    |> order_by(
      [integration],
      asc: integration.provider,
      desc: integration.active,
      asc: integration.inserted_at
    )
    |> Repo.all()
  end

  def list_integration_statuses(%Scope{user: user}) do
    Integration
    |> where([integration], integration.user_id == ^user.id and integration.active)
    |> select([integration], %{
      provider: integration.provider,
      connection_status: integration.connection_status,
      validation_status: integration.validation_status
    })
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
    query =
      Integration
      |> where(
        [integration],
        integration.user_id == ^user.id and integration.provider == ^provider
      )
      |> order_by([integration], desc: integration.active, desc: integration.inserted_at)
      |> limit(1)

    case Repo.one(query) do
      %Integration{} = integration -> {:ok, integration}
      nil -> {:error, :integration_not_found}
    end
  end

  def get_active_integration_by_provider(%Scope{user: user}, provider) do
    case Repo.get_by(Integration, user_id: user.id, provider: provider, active: true) do
      %Integration{} = integration -> {:ok, integration}
      nil -> {:error, :integration_not_found}
    end
  end

  def list_audit_events(%Scope{user: user}) do
    AuditEvent
    |> where([event], event.actor_user_id == ^user.id)
    |> order_by([event], asc: event.inserted_at, asc: event.id)
    |> Repo.all()
  end

  def connect(scope, provider, authentication_type, credentials, opts \\ [])

  def connect(%Scope{user: user} = scope, provider, "api_key", credentials, opts) do
    integration = %Integration{id: Ecto.UUID.generate(), user_id: user.id}

    changeset =
      Integration.create_changeset(integration, %{
        provider: provider,
        authentication_type: "api_key",
        display_name: opts[:display_name]
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
      |> insert_with_audit(user.id, "api_key_submitted")
      |> activate_first(scope)
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
      ["connected"],
      "api_key",
      "api_key_replaced"
    )
  end

  def reconnect_api_key(%Scope{} = scope, id, generation, credentials, opts \\ []) do
    install_credentials(
      scope,
      id,
      generation,
      credentials,
      opts,
      ["disconnected"],
      "api_key",
      "api_key_submitted"
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
      "oauth",
      "oauth_succeeded"
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
      "oauth",
      "refresh_succeeded"
    )
  end

  def validation_succeeded(%Scope{} = scope, id, generation) do
    update_fenced(scope, id, generation, ["connected"], "validation_succeeded", %{
      validation_status: "valid",
      validated_at: now(),
      validation_error_code: nil
    })
  end

  def validation_invalid(%Scope{} = scope, id, generation) do
    update_fenced(scope, id, generation, ["connected"], "validation_invalid", %{
      validation_status: "invalid",
      validated_at: now(),
      validation_error_code: "invalid_credentials"
    })
  end

  def validation_unavailable(%Scope{} = scope, id, generation, error_code)
      when error_code in @safe_validation_errors do
    update_fenced(scope, id, generation, ["connected"], "validation_unavailable", %{
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
      update_fenced(scope, id, generation, ["connected"], "refresh_invalid_grant", %{
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
    update_fenced(
      scope,
      id,
      generation,
      Integration.connection_statuses(),
      "integration_disconnected",
      %{
        connection_status: "disconnected",
        active: false,
        validation_status: "unverified",
        encrypted_credentials: nil,
        encryption_key_version: nil,
        credential_format_version: nil,
        credential_generation: generation + 1,
        expires_at: nil,
        validated_at: nil,
        refreshed_at: nil,
        validation_error_code: nil
      }
    )
  end

  def activate(%Scope{} = scope, id, generation)
      when is_integer(generation) and generation >= 0 do
    do_activate(scope, id, generation, true)
  end

  def activate(%Scope{}, _id, _generation), do: {:error, :stale_credential_generation}

  defp do_activate(%Scope{user: user}, id, generation, audit?) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> activate_transaction(user.id, id, generation, audit?)
      :error -> {:error, :integration_not_found}
    end
  end

  defp activate_transaction(user_id, id, generation, audit?) do
    Repo.transaction(fn ->
      case lock_provider_integrations(user_id, id) do
        {:ok, integration, provider_integrations} ->
          activate_locked(user_id, integration, provider_integrations, generation, audit?)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp activate_locked(user_id, integration, provider_integrations, generation, audit?) do
    with :ok <- require_generation(integration, generation),
         :ok <- require_connected(integration) do
      if !audit? and Enum.any?(provider_integrations, & &1.active) do
        integration
      else
        switch_active_integration(user_id, integration, audit?)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp switch_active_integration(user_id, integration, audit?) do
    Integration
    |> where(
      [candidate],
      candidate.user_id == ^user_id and candidate.provider == ^integration.provider and
        candidate.active
    )
    |> Repo.update_all(set: [active: false, updated_at: now()])

    integration = integration |> change(active: true, updated_at: now()) |> Repo.update!()
    if audit?, do: audit!(user_id, integration, "integration_activated")
    integration
  end

  def safe_validation_errors, do: @safe_validation_errors

  defp install_credentials(
         scope,
         id,
         generation,
         credentials,
         opts,
         allowed_connections,
         authentication_type,
         audit_event_type
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

      update_fenced(scope, id, generation, allowed_connections, audit_event_type, changes)
    else
      {:error, _reason} = error -> error
    end
  end

  defp require_generation(%Integration{credential_generation: generation}, generation), do: :ok
  defp require_generation(%Integration{}, _generation), do: {:error, :stale_credential_generation}

  defp require_authentication_type(%Integration{authentication_type: type}, type), do: :ok

  defp require_authentication_type(%Integration{}, _type),
    do: {:error, :authentication_type_mismatch}

  defp require_connected(%Integration{connection_status: "connected"}), do: :ok
  defp require_connected(%Integration{}), do: {:error, :integration_not_connected}

  defp activate_first({:ok, %Integration{} = integration}, scope) do
    do_activate(scope, integration.id, integration.credential_generation, false)
  end

  defp activate_first(error, _scope), do: error

  defp lock_provider_integrations(user_id, integration_id) do
    provider =
      Integration
      |> where(
        [integration],
        integration.id == ^integration_id and integration.user_id == ^user_id
      )
      |> select([integration], integration.provider)
      |> Repo.one()

    case provider do
      nil ->
        {:error, :integration_not_found}

      provider ->
        lock_provider_rows(user_id, provider, integration_id)
    end
  end

  defp lock_provider_rows(user_id, provider, integration_id) do
    # Every switch takes the provider's rows in the same order. Locking the
    # requested row first would let two concurrent switches deadlock while
    # each waits for the other's target row.
    provider_integrations =
      Integration
      |> where(
        [candidate],
        candidate.user_id == ^user_id and candidate.provider == ^provider
      )
      |> order_by([candidate], asc: candidate.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    case Enum.find(provider_integrations, &(&1.id == integration_id)) do
      %Integration{} = integration ->
        {:ok, integration, provider_integrations}

      nil ->
        {:error, :integration_not_found}
    end
  end

  defp update_fenced(
         %Scope{user: user},
         id,
         generation,
         allowed_connections,
         audit_event_type,
         changes
       )
       when is_integer(generation) and generation >= 0 do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Repo.transaction(fn ->
          integration =
            execute_fenced_update(user.id, id, generation, allowed_connections, changes)

          audit!(user.id, integration, audit_event_type)
          integration
        end)

      :error ->
        {:error, :stale_credential_generation}
    end
  end

  defp update_fenced(
         %Scope{},
         _id,
         _generation,
         _allowed_connections,
         _audit_event_type,
         _changes
       ),
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
    if constraint_error?(changeset, :foreign),
      do: {:error, :integration_owner_not_found},
      else: error
  end

  defp normalize_insert_result(result), do: result

  defp insert_with_audit(changeset, actor_user_id, event_type) do
    Repo.transaction(fn ->
      case changeset |> Repo.insert() |> normalize_insert_result() do
        {:ok, integration} ->
          audit!(actor_user_id, integration, event_type)
          integration

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp audit!(actor_user_id, integration, event_type) do
    %AuditEvent{actor_user_id: actor_user_id, integration_id: integration.id}
    |> AuditEvent.changeset(%{
      provider: integration.provider,
      event_type: event_type,
      credential_generation: integration.credential_generation
    })
    |> Repo.insert!()
  end

  defp constraint_error?(changeset, type) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      metadata[:constraint] == type
    end)
  end

  defp now, do: DateTime.utc_now()
end
