defmodule Kodo.Integrations.OAuthRefresh do
  @moduledoc "Runs generation-fenced, just-in-time OAuth refreshes as finite tasks."

  alias Kodo.Accounts.Scope
  alias Kodo.Integrations
  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.Integration
  alias Kodo.Integrations.RefreshTokens

  @refresh_buffer_seconds 5 * 60
  @wait_timeout_ms 12_000
  @wait_interval_ms 250

  def ensure_fresh(%Scope{} = scope, %Integration{} = integration, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    buffer = Keyword.get(opts, :refresh_buffer_seconds, @refresh_buffer_seconds)

    if Keyword.get(opts, :force, false) or refresh_due?(integration, now, buffer) do
      refresh(scope, integration, opts)
    else
      {:ok, integration}
    end
  end

  defp refresh(scope, integration, opts) do
    owner_id = Keyword.get_lazy(opts, :claim_owner_id, &Ecto.UUID.generate/0)

    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :wait_timeout, @wait_timeout_ms)

    if is_binary(owner_id) do
      claim_or_wait(scope, integration, owner_id, deadline, opts)
    else
      {:error, :provider_unavailable}
    end
  end

  defp claim_or_wait(scope, integration, owner_id, deadline, opts) do
    case Integrations.claim_refresh(
           scope,
           integration.id,
           integration.credential_generation,
           owner_id
         ) do
      {:ok, claim} ->
        run_claim(scope, claim, opts)

      {:error, :refresh_in_progress} ->
        wait_for_claim(scope, integration, owner_id, deadline, opts)

      {:error, :stale_credential_generation} ->
        current_result(scope, integration)

      {:error, :integration_reauthorization_required} ->
        {:error, :integration_reauthorization_required}

      {:error, _reason} ->
        {:error, :provider_unavailable}
    end
  end

  defp wait_for_claim(scope, integration, owner_id, deadline, opts) do
    if System.monotonic_time(:millisecond) < deadline do
      receive do
      after
        @wait_interval_ms -> claim_or_wait(scope, integration, owner_id, deadline, opts)
      end
    else
      current_result(scope, integration)
    end
  end

  defp run_claim(scope, claim, opts) do
    supervisor = Keyword.get(opts, :supervisor, Kodo.ControlPlaneTaskSupervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        perform(scope, claim, opts)
      end)

    case Task.yield(task, Keyword.get(opts, :wait_timeout, @wait_timeout_ms)) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        {:error, :provider_unavailable}

      nil ->
        # The caller is bounded, but an admitted worker must retain ownership of a rotated-token
        # response long enough to persist it. Ignoring detaches the eventual task reply without
        # cancelling the finite supervised operation.
        _result = Task.ignore(task)
        {:error, :provider_unavailable}
    end
  end

  defp perform(scope, claim, opts) do
    client = Keyword.get(opts, :client, configured_client())
    client_options = Keyword.get(opts, :client_options, [])

    with {:ok, admitted} <- Integrations.admit_refresh_claim(scope, claim),
         {:ok, current} <- CredentialEncryption.decrypt(admitted),
         {:ok, refresh_token} <- fetch_refresh_token(current),
         {:ok, response} <- safe_refresh(client, refresh_token, client_options),
         {:ok, normalized} <- RefreshTokens.normalize(response, current),
         {:ok, integration} <-
           Integrations.refresh_succeeded(
             scope,
             claim.id,
             claim.refresh_claim_generation,
             normalized.credentials,
             expires_at: normalized.expires_at,
             refreshed_at: DateTime.utc_now()
           ) do
      {:ok, integration}
    else
      {:error, :invalid_grant} ->
        require_reauthorization(scope, claim, "refresh_invalid_grant")

      {:error, :refresh_account_identity_mismatch} ->
        require_reauthorization(scope, claim, "refresh_account_identity_mismatch")

      {:error, :stale_credential_generation} ->
        current_result(scope, claim)

      {:error, :stale_refresh_claim} ->
        current_result(scope, claim)

      {:error, _reason} ->
        _result = Integrations.fail_refresh(scope, claim)
        {:error, :provider_unavailable}
    end
  end

  defp require_reauthorization(scope, claim, error_code) do
    case Integrations.require_refresh_reauthorization(scope, claim, error_code) do
      {:ok, _integration} -> {:error, :integration_reauthorization_required}
      {:error, :stale_refresh_claim} -> current_result(scope, claim)
      {:error, _reason} -> {:error, :provider_unavailable}
    end
  end

  defp current_result(scope, integration) do
    case Integrations.get_integration(scope, integration.id) do
      {:ok, %{connection_status: "connected"} = current}
      when current.refresh_source_generation == integration.credential_generation ->
        {:ok, current}

      {:ok, %{connection_status: "reauthorization_required"}} ->
        {:error, :integration_reauthorization_required}

      _other ->
        {:error, :provider_unavailable}
    end
  end

  defp refresh_due?(
         %Integration{
           provider: "openai_codex",
           authentication_type: "oauth",
           expires_at: expires_at
         },
         %DateTime{} = now,
         buffer
       )
       when is_integer(buffer) and buffer >= 0 do
    not match?(%DateTime{}, expires_at) or
      DateTime.compare(expires_at, DateTime.add(now, buffer, :second)) != :gt
  end

  defp refresh_due?(_integration, _now, _buffer), do: false

  defp fetch_refresh_token(%{"refresh_token" => token})
       when is_binary(token) and byte_size(token) > 0,
       do: {:ok, token}

  defp fetch_refresh_token(_current), do: {:error, :oauth_refresh_response_invalid}

  defp safe_refresh(client, refresh_token, options) do
    try do
      client.refresh(refresh_token, options)
    rescue
      _exception -> {:error, :provider_unavailable}
    catch
      _kind, _reason -> {:error, :provider_unavailable}
    end
  end

  defp configured_client do
    Application.get_env(:kodo, :oauth_refresh_client, Kodo.Integrations.ReqRefreshClient)
  end
end
