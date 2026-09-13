defmodule Kodo.Integrations.OAuthAccessValidation do
  @moduledoc "Validates ChatGPT subscription access through the bounded refresh contract."

  alias Kodo.Accounts.Scope
  alias Kodo.Integrations
  alias Kodo.Integrations.Integration
  alias Kodo.Integrations.OAuthRefresh

  def start(%Scope{} = scope, %{id: id, credential_generation: generation}) do
    Task.Supervisor.async_nolink(Kodo.ControlPlaneTaskSupervisor, fn ->
      validate(scope, id, generation)
    end)
  end

  @doc false
  def validate(%Scope{} = scope, id, generation, opts \\ []) do
    with {:ok, integration} <- Integrations.get_integration(scope, id),
         :ok <- admit(integration, generation) do
      case OAuthRefresh.ensure_fresh(scope, integration, Keyword.put(opts, :force, true)) do
        {:ok, refreshed} ->
          scope
          |> Integrations.validation_succeeded(refreshed.id, refreshed.credential_generation)
          |> broadcast_result(refreshed)

        {:error, :provider_unavailable} = error ->
          result =
            Integrations.validation_unavailable(
              scope,
              integration.id,
              integration.credential_generation,
              "provider_unavailable"
            )

          _result = broadcast_result(result, integration)
          error

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp admit(
         %Integration{
           provider: "openai_codex",
           authentication_type: "oauth",
           connection_status: "connected",
           credential_generation: generation
         },
         generation
       ),
       do: :ok

  defp admit(%Integration{}, _generation), do: {:error, :stale_credential_generation}

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
