defmodule Kodo.Integrations.DeviceAuthorization do
  @moduledoc "Runs finite, durable ChatGPT device authorization tasks."

  alias Kodo.Accounts.Scope
  alias Kodo.Cluster.InstanceManager
  alias Kodo.Integrations
  alias Kodo.Integrations.DeviceAuthorizationAttempt
  alias Kodo.Integrations.DeviceAuthorizationTokens

  @lease_renewal_interval_ms 15_000
  @verification_url "https://auth.openai.com/codex/device"

  def begin(%Scope{} = scope, integration_id, expected_generation, opts \\ []) do
    client = Keyword.get(opts, :client, configured_client())
    client_options = Keyword.get(opts, :client_options, [])

    with {:ok, created} <- safe_create(client, client_options),
         {:ok, attempt} <-
           Integrations.begin_device_authorization(
             scope,
             integration_id,
             expected_generation,
             created.payload,
             created.polling_interval_ms
           ),
         {:ok, task} <- resume(scope, integration_id, opts) do
      {:ok,
       %{
         attempt: attempt,
         task: task,
         verification_url: created.verification_url
       }}
    end
  end

  def resume(%Scope{} = scope, integration_id, opts \\ []) do
    claim_owner_id = Keyword.get_lazy(opts, :claim_owner_id, &InstanceManager.current_boot_id/0)
    supervisor = Keyword.get(opts, :supervisor, Kodo.ControlPlaneTaskSupervisor)

    with owner when is_binary(owner) <- claim_owner_id,
         {:ok, {claim, payload}} <-
           Integrations.claim_device_authorization(scope, integration_id, owner) do
      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          run(scope, claim, payload, opts)
        end)

      {:ok, task}
    else
      nil -> {:error, :device_authorization_owner_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def run(
        %Scope{} = scope,
        %DeviceAuthorizationAttempt{} = claim,
        payload,
        opts \\ []
      ) do
    client = Keyword.get(opts, :client, configured_client())
    client_options = Keyword.get(opts, :client_options, [])
    continue(scope, claim, payload, client, client_options)
  end

  defp continue(scope, claim, %{"device_auth_id" => _, "user_code" => _}, client, options) do
    with {:ok, {admission, payload}} <- await_poll_admission(scope, claim),
         result <- safe_poll(client, payload, options) do
      case result do
        :pending ->
          continue(scope, admission, payload, client, options)

        {:ok, exchange_payload} ->
          persist_and_exchange(scope, admission, exchange_payload, client, options)

        {:error, reason} ->
          fail(scope, admission, reason)
      end
    else
      {:error, reason} -> stop(reason)
    end
  end

  defp continue(scope, claim, %{"authorization_code" => _} = _payload, client, options) do
    exchange(scope, claim, client, options)
  end

  defp continue(scope, claim, _payload, _client, _options) do
    fail(scope, claim, :device_authorization_response_invalid)
  end

  defp await_poll_admission(scope, claim) do
    delay = max(DateTime.diff(claim.next_poll_at, DateTime.utc_now(), :millisecond), 0)

    if delay == 0 do
      case Integrations.admit_device_authorization_poll(scope, claim) do
        {:error, :device_authorization_poll_not_due} -> wait_and_renew(scope, claim, 1)
        result -> result
      end
    else
      wait_and_renew(scope, claim, min(delay, @lease_renewal_interval_ms))
    end
  end

  defp wait_and_renew(scope, claim, delay) do
    receive do
    after
      delay ->
        case Integrations.renew_device_authorization_claim(
               scope,
               claim.id,
               claim.attempt_generation,
               claim.claim_owner_id,
               claim.claim_epoch
             ) do
          {:ok, {renewed, _payload}} -> await_poll_admission(scope, renewed)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp persist_and_exchange(scope, claim, payload, client, options) do
    case Integrations.store_device_authorization_exchange(scope, claim, payload) do
      {:ok, persisted} -> exchange(scope, persisted, client, options)
      {:error, reason} -> stop(reason)
    end
  end

  defp exchange(scope, claim, client, options) do
    with {:ok, {admission, payload}} <-
           Integrations.admit_device_authorization_exchange(scope, claim),
         {:ok, tokens} <- safe_exchange(client, payload, options),
         {:ok, normalized} <- DeviceAuthorizationTokens.normalize(tokens),
         {:ok, _integration} <-
           Integrations.complete_device_authorization(
             scope,
             admission,
             normalized.credentials,
             normalized.expires_at
           ) do
      :ok
    else
      {:error, :stale_device_authorization_claim} = error -> stop(error)
      {:error, reason} -> fail(scope, claim, reason)
    end
  end

  defp fail(scope, claim, reason) do
    case Integrations.fail_device_authorization(scope, claim, terminal_error(reason)) do
      {:ok, _attempt} -> {:error, reason}
      {:error, stale_reason} -> stop(stale_reason)
    end
  end

  defp stop({:error, reason}), do: {:error, reason}
  defp stop(reason), do: {:error, reason}

  defp terminal_error(:redirect), do: "redirect"
  defp terminal_error(:device_authorization_rejected), do: "provider_rejected"
  defp terminal_error(:device_authorization_response_invalid), do: "response_invalid"
  defp terminal_error(_reason), do: "provider_unavailable"

  defp safe_create(client, options) do
    case safe_client_call(fn -> client.create(options) end) do
      {:ok,
       %{
         payload: payload,
         polling_interval_ms: interval,
         verification_url: verification_url
       } = created}
      when is_map(payload) and is_integer(interval) and verification_url == @verification_url ->
        {:ok, created}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _invalid ->
        {:error, :device_authorization_response_invalid}
    end
  end

  defp safe_poll(client, payload, options) do
    case safe_client_call(fn -> client.poll(payload, options) end) do
      :pending -> :pending
      {:ok, exchange_payload} when is_map(exchange_payload) -> {:ok, exchange_payload}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _invalid -> {:error, :device_authorization_response_invalid}
    end
  end

  defp safe_exchange(client, payload, options) do
    case safe_client_call(fn -> client.exchange(payload, options) end) do
      {:ok, tokens} when is_map(tokens) -> {:ok, tokens}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _invalid -> {:error, :device_authorization_response_invalid}
    end
  end

  defp safe_client_call(operation) do
    try do
      operation.()
    rescue
      _exception -> {:error, :provider_unavailable}
    catch
      _kind, _reason -> {:error, :provider_unavailable}
    end
  end

  defp configured_client do
    Application.get_env(
      :kodo,
      :device_authorization_client,
      Kodo.Integrations.ReqDeviceAuthorizationClient
    )
  end
end
