defmodule Kodo.Integrations.OpenAIValidation do
  @moduledoc """
  Runs a bounded, generation-fenced OpenAI API-key metadata probe.

  The task decrypts immediately before its one external operation and retains
  neither the key nor provider response. Only bounded validation outcomes are
  allowed to cross back into durable integration state.
  """

  alias Kodo.Accounts.Scope
  alias Kodo.Integrations
  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.Integration

  @provider "openai"
  @probe_timeout 5_000

  def start(
        %Scope{} = scope,
        %{id: integration_id, credential_generation: generation}
      ) do
    Task.Supervisor.async_nolink(Kodo.ControlPlaneTaskSupervisor, fn ->
      case validate(scope, integration_id, generation) do
        {:ok, _integration} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc false
  def validate(%Scope{} = scope, id, generation, opts \\ []) do
    client = Keyword.get(opts, :client, configured_client())
    timeout = Keyword.get(opts, :timeout, @probe_timeout)

    with {:ok, integration} <- Integrations.get_integration(scope, id),
         :ok <- admit(integration, generation),
         {:ok, payload} <- CredentialEncryption.decrypt(integration),
         {:ok, api_key} <- fetch_api_key(payload),
         outcome <- bounded_probe(client, api_key, timeout) do
      persist(scope, integration, outcome)
    end
  end

  defp configured_client do
    Application.get_env(
      :kodo,
      :openai_validation_client,
      Kodo.Integrations.ReqOpenAIValidationClient
    )
  end

  defp admit(
         %Integration{
           provider: @provider,
           authentication_type: "api_key",
           connection_status: "connected",
           credential_generation: generation
         },
         generation
       ),
       do: :ok

  defp admit(%Integration{}, _generation), do: {:error, :stale_credential_generation}

  defp fetch_api_key(%{"api_key" => api_key}) when is_binary(api_key) and api_key != "",
    do: {:ok, api_key}

  defp fetch_api_key(_payload), do: {:error, :credential_payload_invalid}

  # The HTTP client's timeouts bound individual transport phases. This outer
  # deadline also bounds response decoding and misbehaving client adapters so a
  # validation task cannot retain an operation-local key indefinitely.
  defp bounded_probe(client, api_key, timeout) when is_integer(timeout) and timeout > 0 do
    task =
      Task.Supervisor.async_nolink(Kodo.ControlPlaneTaskSupervisor, fn ->
        safe_probe(client, api_key)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> outcome
      {:exit, _reason} -> {:unavailable, "provider_unavailable"}
      nil -> {:unavailable, "timeout"}
    end
  end

  # Normalize inside the supervised task so its crash logger can never inspect
  # a provider exception or response containing operation-local credentials.
  defp safe_probe(client, api_key) do
    try do
      client.get_models(api_key) |> classify_response()
    rescue
      _exception -> {:unavailable, "provider_unavailable"}
    catch
      _kind, _reason -> {:unavailable, "provider_unavailable"}
    end
  end

  defp classify_response({:ok, status, _body}) when status in 200..299, do: :valid
  defp classify_response({:ok, 401, body}), do: classify_unauthorized(body)

  defp classify_response({:ok, status, _body}) when status in 300..399,
    do: {:unavailable, "provider_unavailable"}

  defp classify_response({:ok, 429, _body}), do: {:unavailable, "rate_limited"}
  defp classify_response({:ok, _status, _body}), do: {:unavailable, "provider_unavailable"}
  defp classify_response({:error, :timeout}), do: {:unavailable, "timeout"}
  defp classify_response({:error, :tls_error}), do: {:unavailable, "tls_error"}
  defp classify_response({:error, :redirect}), do: {:unavailable, "provider_unavailable"}
  defp classify_response({:error, :network_error}), do: {:unavailable, "network_error"}
  defp classify_response({:error, _reason}), do: {:unavailable, "provider_unavailable"}

  defp classify_unauthorized(%{"error" => %{"code" => code}})
       when code in ["invalid_api_key", "key_revoked"],
       do: :invalid

  defp classify_unauthorized(_body), do: {:unavailable, "provider_unavailable"}

  defp persist(scope, integration, :valid) do
    scope
    |> Integrations.validation_succeeded(integration.id, integration.credential_generation)
    |> broadcast_result(integration)
  end

  defp persist(scope, integration, :invalid) do
    scope
    |> Integrations.validation_invalid(integration.id, integration.credential_generation)
    |> broadcast_result(integration)
  end

  defp persist(scope, integration, {:unavailable, error_code}) do
    scope
    |> Integrations.validation_unavailable(
      integration.id,
      integration.credential_generation,
      error_code
    )
    |> broadcast_result(integration)
  end

  defp broadcast_result({:ok, validated} = result, integration) do
    Phoenix.PubSub.broadcast(
      Kodo.PubSub,
      "integration:#{integration.user_id}",
      {:integration_validation_finished, validated.id, validated.credential_generation}
    )

    result
  end

  defp broadcast_result(error, _integration), do: error
end
