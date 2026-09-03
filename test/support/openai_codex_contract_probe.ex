defmodule Kodo.Test.OpenAICodexContractProbe do
  @moduledoc false

  alias ReqLLM.Providers.OpenAICodex
  alias ReqLLM.Streaming.SSE
  alias ReqLLM.TimeoutBudget

  @probe_step :kodo_codex_contract_model_probe

  @doc """
  Executes a buffered Codex request and returns the model identity from the
  provider's terminal SSE event alongside ReqLLM's decoded response.

  This test-only wrapper exists because ReqLLM 1.19.0 does not retain the
  provider's `response.model` field while decoding Codex SSE and later fills
  `ReqLLM.Response.model` from the requested catalog selector. Reading the
  public response would therefore turn the assertion into a test of the input.

  The probe runs immediately before ReqLLM's decoder, retains only the model
  string, and lets the normal decoder process the unchanged response. Keeping
  it outside production code avoids depending on ReqLLM internals at runtime.
  """
  def generate_text(model, prompt, opts) do
    owner = self()
    ref = make_ref()
    deadline = TimeoutBudget.deadline(opts)

    with {:ok, request} <- OpenAICodex.prepare_request(:chat, model, prompt, opts),
         {:ok, request} <- insert_probe(request, owner, ref),
         {:ok, %Req.Response{status: status, body: response}} when status in 200..299 <-
           TimeoutBudget.request(request, deadline),
         {:ok, provider_model} <- receive_model(ref) do
      {:ok, response, provider_model}
    else
      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  def provider_model_from_sse(body) when is_binary(body) do
    body
    |> SSE.parse_sse_binary()
    |> Enum.find_value(&terminal_event_model/1)
  end

  defp insert_probe(request, owner, ref) do
    step = fn {req, response} ->
      provider_model =
        case response do
          %Req.Response{status: status, body: body} when status in 200..299 and is_binary(body) ->
            provider_model_from_sse(body)

          _other ->
            nil
        end

      send(owner, {__MODULE__, ref, provider_model})
      {req, response}
    end

    {leading, trailing} =
      Enum.split_while(request.response_steps, fn {name, _step} ->
        name != :llm_decode_response
      end)

    case trailing do
      [] ->
        # This is an intentional dependency-version tripwire: running the
        # probe after decoding would silently observe ReqLLM's synthetic model.
        {:error, :req_llm_codex_decoder_step_missing}

      _decoder_and_following_steps ->
        {:ok, %{request | response_steps: leading ++ [{@probe_step, step} | trailing]}}
    end
  end

  defp receive_model(ref) do
    receive do
      {__MODULE__, ^ref, model} when is_binary(model) and model != "" -> {:ok, model}
      {__MODULE__, ^ref, _missing} -> {:error, :provider_model_missing}
    after
      0 -> {:error, :provider_model_probe_missing}
    end
  end

  defp terminal_event_model(%{data: data} = event) when is_map(data) do
    type = event[:event] || data["event"] || data["type"]

    if type in ["response.completed", "response.done"] do
      get_in(data, ["response", "model"])
    end
  end

  defp terminal_event_model(_event), do: nil
end
