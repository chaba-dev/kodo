defmodule Kodo.Integrations.APIKeyValidation do
  @moduledoc """
  Runs bounded, generation-fenced API-key metadata probes.

  The task decrypts immediately before its one external operation and retains
  neither the key nor provider response. Only bounded validation outcomes are
  allowed to cross back into durable integration state.
  """

  alias Kodo.Accounts.Scope
  alias Kodo.Integrations
  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.Integration

  @providers ~w(openai anthropic openrouter)
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
         outcome <- bounded_probe(client, integration.provider, api_key, timeout) do
      persist(scope, integration, outcome)
    end
  end

  defp configured_client do
    Application.get_env(
      :kodo,
      :api_key_validation_client,
      Kodo.Integrations.ReqAPIKeyValidationClient
    )
  end

  defp admit(
         %Integration{
           provider: provider,
           authentication_type: "api_key",
           connection_status: "connected",
           credential_generation: generation
         },
         generation
       )
       when provider in @providers,
       do: :ok

  defp admit(%Integration{}, _generation), do: {:error, :stale_credential_generation}

  defp fetch_api_key(%{"api_key" => api_key}) when is_binary(api_key) and api_key != "",
    do: {:ok, api_key}

  defp fetch_api_key(_payload), do: {:error, :credential_payload_invalid}

  # The HTTP client's timeouts bound individual transport phases. This outer
  # deadline also bounds response decoding and misbehaving client adapters so a
  # validation task cannot retain an operation-local key indefinitely.
  defp bounded_probe(client, provider, api_key, timeout)
       when is_integer(timeout) and timeout > 0 do
    task =
      Task.Supervisor.async_nolink(Kodo.ControlPlaneTaskSupervisor, fn ->
        safe_probe(client, provider, api_key)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> outcome
      {:exit, _reason} -> {:unavailable, "provider_unavailable"}
      nil -> {:unavailable, "timeout"}
    end
  end

  # Normalize inside the supervised task so its crash logger can never inspect
  # a provider exception or response containing operation-local credentials.
  defp safe_probe(client, provider, api_key) do
    try do
      client.get_metadata(provider, api_key) |> classify_response(provider)
    rescue
      _exception -> {:unavailable, "provider_unavailable"}
    catch
      _kind, _reason -> {:unavailable, "provider_unavailable"}
    end
  end

  defp classify_response({:ok, status, %{"data" => data}}, provider)
       when status in 200..299 and provider in ~w(openai anthropic) and is_list(data),
       do: :valid

  defp classify_response({:ok, status, %{"data" => data}}, "openrouter")
       when status in 200..299 and is_map(data),
       do: :valid

  defp classify_response({:ok, status, _body}, _provider) when status in 200..299,
    do: {:unavailable, "provider_unavailable"}

  defp classify_response({:ok, 401, body}, provider),
    do: classify_unauthorized(provider, body)

  defp classify_response({:ok, status, _body}, _provider) when status in 300..399,
    do: {:unavailable, "provider_unavailable"}

  defp classify_response({:ok, 429, _body}, _provider), do: {:unavailable, "rate_limited"}

  defp classify_response({:ok, _status, _body}, _provider),
    do: {:unavailable, "provider_unavailable"}

  defp classify_response({:error, :timeout}, _provider), do: {:unavailable, "timeout"}
  defp classify_response({:error, :tls_error}, _provider), do: {:unavailable, "tls_error"}

  defp classify_response({:error, :redirect}, _provider),
    do: {:unavailable, "provider_unavailable"}

  defp classify_response({:error, :network_error}, _provider),
    do: {:unavailable, "network_error"}

  defp classify_response({:error, _reason}, _provider),
    do: {:unavailable, "provider_unavailable"}

  defp classify_unauthorized("openai", %{"error" => %{"code" => code}})
       when code in ["invalid_api_key", "key_revoked"],
       do: :invalid

  defp classify_unauthorized("anthropic", %{"error" => %{"type" => "authentication_error"}}),
    do: :invalid

  defp classify_unauthorized("openrouter", %{"error" => %{"code" => 401}}), do: :invalid

  defp classify_unauthorized(_provider, _body),
    do: {:unavailable, "provider_unavailable"}

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
