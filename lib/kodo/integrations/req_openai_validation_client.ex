defmodule Kodo.Integrations.ReqOpenAIValidationClient do
  @moduledoc """
  Performs OpenAI validation against Kodo's fixed metadata endpoint.

  Redirects are deliberately disabled for credential-bearing requests. Even a
  same-origin endpoint move must be reviewed in code rather than forwarding a
  user's API key to a response-selected destination.
  """

  @behaviour Kodo.Integrations.OpenAIValidationClient

  @models_url "https://api.openai.com/v1/models"
  @timeout 5_000

  @impl true
  def get_models(api_key), do: get_models(api_key, [])

  @doc false
  def get_models(api_key, req_options) when is_binary(api_key) and is_list(req_options) do
    # Tests may replace only the transport plug; the credential-bearing origin
    # and redirect policy remain immutable even through this test seam.
    req_options = Keyword.take(req_options, [:plug])

    options =
      [
        url: @models_url,
        headers: [{"authorization", "Bearer #{api_key}"}],
        max_redirects: 0,
        retry: false,
        receive_timeout: @timeout,
        connect_options: [timeout: @timeout]
      ] ++ req_options

    case Req.get(options) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, status, body}

      {:error, %Req.TooManyRedirectsError{}} ->
        {:error, :redirect}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, transport_error(reason)}

      {:error, _error} ->
        {:error, :network_error}
    end
  end

  defp transport_error(:timeout), do: :timeout

  defp transport_error(reason) when reason in [:closed, :econnrefused, :nxdomain],
    do: :network_error

  defp transport_error({:tls_alert, _detail}), do: :tls_error
  defp transport_error(_reason), do: :network_error
end
