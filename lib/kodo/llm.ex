defmodule Kodo.LLM do
  @moduledoc """
  Provider-independent boundary for one explicit agent model step.

  Generation goes through this facade rather than directly through ReqLLM so a
  request must resolve a user-owned integration before ReqLLM can consult its
  process-wide or environment credential fallbacks.
  """

  alias Kodo.Accounts.Scope
  alias Kodo.LLM.Credential
  alias Kodo.LLM.CredentialResolver
  alias Kodo.LLM.IntegrationRef
  alias Kodo.LLM.ProviderError

  @credential_option_keys ~w(api_key access_token auth_mode oauth_file auth_file provider_options chatgpt_account_id)a

  @type tool :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:parameters) => map()
        }

  @type result :: %{
          required(:type) => :final_answer | :tool_calls,
          required(:text) => String.t(),
          required(:tool_calls) => [map()],
          required(:usage) => map() | nil,
          optional(:assistant) => map()
        }

  @callback generate(LLMDB.Model.t(), [map()], [tool()], Credential.t(), keyword()) ::
              {:ok, result()} | {:error, term()}

  @callback generate_object(LLMDB.Model.t(), [map()], map(), Credential.t(), keyword()) ::
              {:ok, %{object: map(), usage: map() | nil}} | {:error, term()}

  @callback validate_model(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}

  @doc "Resolves a model and captures non-secret integration metadata for later admission."
  def resolve_integration(%Scope{} = scope, model) do
    with {:ok, resolved_model} <- resolve_model(model) do
      case CredentialResolver.reference(scope, resolved_model) do
        {:ok, reference} ->
          {:ok, resolved_model, reference}

        {:error, reason}
        when reason in [
               :integration_not_found,
               :integration_disconnected,
               :integration_reauthorization_required,
               :integration_invalid
             ] ->
          {:error, ProviderError.from_integration(reason, resolved_model)}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc "Generates text after rechecking and decrypting the referenced credential."
  def generate(
        %Scope{} = scope,
        %LLMDB.Model{} = model,
        %IntegrationRef{} = reference,
        messages,
        tools,
        opts
      ) do
    adapter = Keyword.get(opts, :adapter, adapter())
    adapter_opts = Keyword.delete(opts, :adapter)

    with :ok <- reject_credential_options(adapter_opts),
         {:ok, credential} <- CredentialResolver.resolve(scope, model, reference) do
      adapter.generate(model, messages, tools, credential, adapter_opts)
    end
  end

  @doc "Generates a structured object after scoped credential admission."
  def generate_object(
        %Scope{} = scope,
        %LLMDB.Model{} = model,
        %IntegrationRef{} = reference,
        messages,
        schema,
        opts
      ) do
    adapter = Keyword.get(opts, :adapter, adapter())
    adapter_opts = Keyword.delete(opts, :adapter)

    with :ok <- reject_credential_options(adapter_opts),
         {:ok, credential} <- CredentialResolver.resolve(scope, model, reference) do
      adapter.generate_object(model, messages, schema, credential, adapter_opts)
    end
  end

  def adapter, do: Application.get_env(:kodo, :llm_adapter, Kodo.LLM.ReqLLM)

  defp resolve_model(model) do
    case ReqLLM.model(model) do
      {:ok, %LLMDB.Model{} = resolved} -> {:ok, resolved}
      {:error, _reason} -> {:error, :malformed_model}
    end
  end

  defp reject_credential_options(opts) do
    if Enum.any?(@credential_option_keys, &Keyword.has_key?(opts, &1)),
      do: {:error, :credential_options_not_allowed},
      else: :ok
  end
end
