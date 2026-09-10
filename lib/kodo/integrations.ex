defmodule Kodo.Integrations do
  @moduledoc "Owns scoped provider-integration credential lifecycle transitions."

  import Ecto.Changeset
  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Kodo.Accounts.Scope
  alias Kodo.Accounts.User
  alias Kodo.Integrations.AuditEvent
  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.DeviceAuthorizationAttempt
  alias Kodo.Integrations.DeviceAuthorizationEncryption
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
  @device_authorization_lifetime_seconds 15 * 60
  @device_authorization_secret_max_bytes 1_024
  @device_authorization_cleanup_age_seconds 24 * 60 * 60
  @secret_repo_options [log: false, telemetry_event: nil]

  def list_integrations(%Scope{user: user}) do
    Integration
    |> where([integration], integration.user_id == ^user.id)
    |> order_by(
      [integration],
      asc: integration.provider,
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

  def begin_device_authorization(
        %Scope{user: user},
        integration_id,
        expected_generation,
        payload,
        polling_interval_ms
      )
      when is_integer(expected_generation) and expected_generation >= 0 and
             is_integer(polling_interval_ms) and polling_interval_ms >= 0 and
             polling_interval_ms <= 900_000 do
    with {:ok, integration_id} <- cast_uuid(integration_id),
         :ok <- validate_device_authorization_payload(payload) do
      Repo.transaction(fn ->
        begin_device_authorization_locked(
          user.id,
          integration_id,
          expected_generation,
          payload,
          polling_interval_ms
        )
      end)
    end
  end

  def begin_device_authorization(%Scope{}, _id, _generation, _payload, _interval),
    do: {:error, :device_authorization_invalid}

  def get_active_device_authorization(%Scope{user: user}, integration_id) do
    with {:ok, integration_id} <- cast_uuid(integration_id) do
      result =
        Repo.transaction(fn ->
          expire_device_authorization(user.id, integration_id)
          read_active_device_authorization(user.id, integration_id)
        end)

      case result do
        {:ok, :not_found} -> {:error, :device_authorization_not_found}
        other -> other
      end
    end
  end

  def cancel_device_authorization(%Scope{user: user}, attempt_id, attempt_generation)
      when is_integer(attempt_generation) and attempt_generation > 0 do
    with {:ok, attempt_id} <- cast_uuid(attempt_id) do
      Repo.transaction(fn ->
        cancel_device_authorization_locked(user.id, attempt_id, attempt_generation)
      end)
    end
  end

  def cancel_device_authorization(%Scope{}, _attempt_id, _attempt_generation),
    do: {:error, :stale_device_authorization}

  def cleanup_device_authorizations(limit \\ 100)

  def cleanup_device_authorizations(limit)
      when is_integer(limit) and limit > 0 and limit <= 1_000 do
    cutoff = DateTime.add(now(), -@device_authorization_cleanup_age_seconds, :second)

    ids =
      DeviceAuthorizationAttempt
      |> where([attempt], attempt.state != "active" and attempt.updated_at < ^cutoff)
      |> order_by([attempt], asc: attempt.updated_at, asc: attempt.id)
      |> select([attempt], attempt.id)
      |> limit(^limit)

    {count, nil} =
      DeviceAuthorizationAttempt
      |> where([attempt], attempt.id in subquery(ids))
      |> Repo.delete_all(@secret_repo_options)

    {:ok, count}
  end

  def cleanup_device_authorizations(_limit), do: {:error, :cleanup_limit_invalid}

  def connect(scope, provider, authentication_type, credentials, opts \\ [])

  def connect(%Scope{user: user}, provider, "api_key", credentials, opts) do
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
      |> insert_connected(user.id, provider, "api_key_submitted")
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
        active: false,
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
    |> notify_integration_change()
  end

  def activate(%Scope{} = scope, id, generation)
      when is_integer(generation) and generation >= 0 do
    scope
    |> do_activate(id, generation, true)
    |> notify_integration_change()
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
      cond do
        integration.active -> integration
        !audit? and Enum.any?(provider_integrations, & &1.active) -> integration
        true -> switch_active_integration(user_id, integration, audit?)
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

  defp begin_device_authorization_locked(
         user_id,
         integration_id,
         expected_generation,
         payload,
         polling_interval_ms
       ) do
    lock_user!(user_id)
    integration = lock_owned_integration!(user_id, integration_id)

    with :ok <- require_generation(integration, expected_generation),
         :ok <- require_device_authorization_integration(integration) do
      start_device_authorization_locked(user_id, integration, payload, polling_interval_ms)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp read_active_device_authorization(user_id, integration_id) do
    query =
      DeviceAuthorizationAttempt
      |> where(
        [attempt],
        attempt.user_id == ^user_id and attempt.integration_id == ^integration_id and
          attempt.state == "active" and
          attempt.provider_deadline > fragment("timezone('UTC', clock_timestamp())")
      )

    case Repo.one(query, @secret_repo_options) do
      %DeviceAuthorizationAttempt{} = attempt -> decrypt_device_authorization(attempt)
      nil -> :not_found
    end
  end

  defp decrypt_device_authorization(attempt) do
    case DeviceAuthorizationEncryption.decrypt(attempt) do
      {:ok, payload} -> {attempt, payload}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp cancel_device_authorization_locked(user_id, attempt_id, attempt_generation) do
    integration_id =
      DeviceAuthorizationAttempt
      |> where([attempt], attempt.id == ^attempt_id and attempt.user_id == ^user_id)
      |> select([attempt], attempt.integration_id)
      |> Repo.one(@secret_repo_options)

    if is_nil(integration_id), do: Repo.rollback(:stale_device_authorization)

    lock_user!(user_id)
    integration = lock_owned_integration!(user_id, integration_id)

    query =
      from attempt in DeviceAuthorizationAttempt,
        where:
          attempt.id == ^attempt_id and attempt.user_id == ^user_id and
            attempt.state == "active" and attempt.attempt_generation == ^attempt_generation

    case Repo.update_all(
           query,
           [set: terminal_attempt_changes("cancelled", nil)],
           @secret_repo_options
         ) do
      {1, nil} -> record_device_authorization_cancellation(user_id, attempt_id, integration)
      {0, nil} -> Repo.rollback(:stale_device_authorization)
    end
  end

  defp record_device_authorization_cancellation(user_id, attempt_id, integration) do
    attempt = Repo.get!(DeviceAuthorizationAttempt, attempt_id, @secret_repo_options)
    audit!(user_id, integration, "device_authorization_cancelled")
    attempt
  end

  defp start_device_authorization_locked(user_id, integration, payload, polling_interval_ms) do
    timestamp = database_now()
    expected_integration_generation = integration.credential_generation + 1

    supersede_active_device_authorization(integration.id, timestamp)

    integration =
      integration
      |> change(
        device_authorization_integration_changes(
          integration,
          expected_integration_generation,
          timestamp
        )
      )
      |> Repo.update!()

    attempt = %DeviceAuthorizationAttempt{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      integration_id: integration.id,
      provider: "openai_codex",
      attempt_generation: next_device_authorization_generation(integration.id),
      expected_integration_generation: expected_integration_generation
    }

    case DeviceAuthorizationEncryption.encrypt(attempt, payload) do
      {:ok, encrypted} ->
        deadline = DateTime.add(timestamp, @device_authorization_lifetime_seconds, :second)
        next_poll_at = DateTime.add(timestamp, polling_interval_ms, :millisecond)

        attempt =
          attempt
          |> Map.merge(encrypted)
          |> DeviceAuthorizationAttempt.create_changeset(%{
            provider: "openai_codex",
            attempt_generation: attempt.attempt_generation,
            expected_integration_generation: expected_integration_generation,
            provider_deadline: deadline,
            polling_interval_ms: polling_interval_ms,
            next_poll_at: next_poll_at
          })
          |> Repo.insert!(@secret_repo_options)

        audit!(user_id, integration, "device_authorization_started")
        attempt

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp device_authorization_integration_changes(%Integration{}, generation, timestamp) do
    [credential_generation: generation, updated_at: timestamp]
  end

  defp supersede_active_device_authorization(integration_id, timestamp) do
    DeviceAuthorizationAttempt
    |> where([attempt], attempt.integration_id == ^integration_id and attempt.state == "active")
    |> Repo.update_all(
      [set: terminal_attempt_changes("cancelled", "superseded", timestamp)],
      @secret_repo_options
    )
  end

  defp next_device_authorization_generation(integration_id) do
    DeviceAuthorizationAttempt
    |> where([attempt], attempt.integration_id == ^integration_id)
    |> select([attempt], coalesce(max(attempt.attempt_generation), 0))
    |> Repo.one()
    |> Kernel.+(1)
  end

  defp expire_device_authorization(user_id, integration_id) do
    DeviceAuthorizationAttempt
    |> where(
      [attempt],
      attempt.user_id == ^user_id and attempt.integration_id == ^integration_id and
        attempt.state == "active" and
        attempt.provider_deadline <= fragment("timezone('UTC', clock_timestamp())")
    )
    |> Repo.update_all(set: terminal_attempt_changes("expired", "deadline_exceeded"))
  end

  defp terminal_attempt_changes(state, error_code, timestamp \\ now()) do
    [
      state: state,
      encrypted_payload: nil,
      encryption_key_version: nil,
      payload_format_version: nil,
      claim_owner_id: nil,
      claim_lease_expires_at: nil,
      terminal_error_code: error_code,
      updated_at: timestamp
    ]
  end

  defp validate_device_authorization_payload(
         %{"device_auth_id" => device_auth_id, "user_code" => user_code} = payload
       )
       when map_size(payload) == 2 do
    if bounded_secret?(device_auth_id) and bounded_secret?(user_code),
      do: :ok,
      else: {:error, :device_authorization_invalid}
  end

  defp validate_device_authorization_payload(_payload),
    do: {:error, :device_authorization_invalid}

  defp bounded_secret?(value) do
    is_binary(value) and byte_size(value) > 0 and
      byte_size(value) <= @device_authorization_secret_max_bytes
  end

  defp require_device_authorization_integration(%Integration{
         provider: "openai_codex",
         authentication_type: "oauth"
       }),
       do: :ok

  defp require_device_authorization_integration(%Integration{}),
    do: {:error, :authentication_type_mismatch}

  defp lock_owned_integration!(user_id, integration_id) do
    case Integration
         |> where(
           [integration],
           integration.id == ^integration_id and integration.user_id == ^user_id
         )
         |> lock("FOR UPDATE")
         |> Repo.one() do
      %Integration{} = integration -> integration
      nil -> Repo.rollback(:integration_not_found)
    end
  end

  defp lock_user!(user_id) do
    case User
         |> where([user], user.id == ^user_id)
         |> select([user], user.id)
         |> lock("FOR KEY SHARE")
         |> Repo.one() do
      ^user_id -> :ok
      nil -> Repo.rollback(:integration_not_found)
    end
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :integration_not_found}
    end
  end

  defp database_now do
    %{rows: [[naive_datetime]]} =
      SQL.query!(Repo, "SELECT timezone('UTC', clock_timestamp())", [])

    DateTime.from_naive!(naive_datetime, "Etc/UTC")
  end

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
        lock_provider_identity(user_id, provider)
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
          maybe_lock_transition(user.id, id, audit_event_type)

          integration =
            execute_fenced_update(user.id, id, generation, allowed_connections, changes)

          maybe_terminalize_device_authorization(user.id, id, audit_event_type)
          integration = maybe_activate_initial_oauth(user.id, integration, audit_event_type)
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

  defp insert_connected(changeset, actor_user_id, provider, event_type) do
    Repo.transaction(fn ->
      lock_provider_identity(actor_user_id, provider)
      first_account? = !provider_account_exists?(actor_user_id, provider)

      result =
        changeset
        |> change(active: first_account?)
        |> Repo.insert()
        |> normalize_insert_result()

      case result do
        {:ok, integration} ->
          audit!(actor_user_id, integration, event_type)
          integration

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp maybe_lock_transition(user_id, integration_id, "oauth_succeeded") do
    case Repo.get_by(Integration, id: integration_id, user_id: user_id) do
      %Integration{provider: provider} -> lock_provider_identity(user_id, provider)
      nil -> :ok
    end
  end

  defp maybe_lock_transition(_user_id, _integration_id, _event_type), do: :ok

  defp maybe_terminalize_device_authorization(user_id, integration_id, "integration_disconnected") do
    DeviceAuthorizationAttempt
    |> where(
      [attempt],
      attempt.user_id == ^user_id and attempt.integration_id == ^integration_id and
        attempt.state == "active"
    )
    |> Repo.update_all(set: terminal_attempt_changes("cancelled", "integration_disconnected"))
  end

  defp maybe_terminalize_device_authorization(_user_id, _integration_id, _event_type), do: :ok

  defp maybe_activate_initial_oauth(
         user_id,
         %{credential_generation: 1} = integration,
         "oauth_succeeded"
       ) do
    if !integration.active and !active_provider_account_exists?(user_id, integration.provider) and
         provider_account_count(user_id, integration.provider) == 1 do
      integration |> change(active: true, updated_at: now()) |> Repo.update!()
    else
      integration
    end
  end

  defp maybe_activate_initial_oauth(_user_id, integration, _event_type), do: integration

  defp provider_account_exists?(user_id, provider) do
    Repo.exists?(
      from integration in Integration,
        where: integration.user_id == ^user_id and integration.provider == ^provider
    )
  end

  defp active_provider_account_exists?(user_id, provider) do
    Repo.exists?(
      from integration in Integration,
        where:
          integration.user_id == ^user_id and integration.provider == ^provider and
            integration.active
    )
  end

  defp provider_account_count(user_id, provider) do
    Repo.aggregate(
      from(integration in Integration,
        where: integration.user_id == ^user_id and integration.provider == ^provider
      ),
      :count
    )
  end

  defp lock_provider_identity(user_id, provider) do
    key = "provider-integration:#{user_id}:#{provider}"

    SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      [key]
    )

    :ok
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

  defp notify_integration_change({:ok, integration} = result) do
    Phoenix.PubSub.broadcast(
      Kodo.PubSub,
      "integration:#{integration.user_id}",
      {:integration_changed, integration.id, integration.credential_generation}
    )

    result
  end

  defp notify_integration_change(error), do: error

  defp constraint_error?(changeset, type) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      metadata[:constraint] == type
    end)
  end

  defp now, do: DateTime.utc_now()
end
