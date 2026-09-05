defmodule Kodo.Integrations.ReqAPIKeyValidationClient do
  @moduledoc """
  Performs API-key validation against Kodo's fixed provider metadata endpoints.

  Redirects are deliberately disabled for credential-bearing requests. Even a
  same-origin endpoint move must be reviewed in code rather than forwarding a
  user's API key to a response-selected destination.
  """

  @behaviour Kodo.Integrations.APIKeyValidationClient

  @timeout 5_000

  @impl true
  def get_metadata(provider, api_key), do: get_metadata(provider, api_key, [])

  @doc false
  def get_metadata(provider, api_key, req_options)
      when provider in ~w(openai anthropic openrouter) and is_binary(api_key) and
             is_list(req_options) do
    # Tests may replace only the transport boundary; the credential-bearing
    # origin and redirect policy remain immutable even through these seams.
    req_options = Keyword.take(req_options, [:plug, :finch_request])
    {url, headers} = request_identity(provider, api_key)

    options =
      [
        url: url,
        headers: headers,
        max_redirects: 0,
        retry: false,
        receive_timeout: @timeout,
        request_timeout: @timeout,
        finch: [
          pool_timeout: @timeout,
          conn_opts: [transport_opts: [timeout: @timeout]]
        ]
      ] ++ req_options

    try do
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
    rescue
      exception in RuntimeError ->
        # Finch currently turns its structured checkout timeout into a
        # RuntimeError. Normalize only that dependency-owned failure here;
        # unrelated programming errors must remain visible.
        if String.starts_with?(
             Exception.message(exception),
             "Finch was unable to provide a connection within the timeout"
           ) do
          {:error, :timeout}
        else
          reraise exception, __STACKTRACE__
        end
    end
  end

  defp request_identity("openai", api_key) do
    {"https://api.openai.com/v1/models", [{"authorization", "Bearer #{api_key}"}]}
  end

  defp request_identity("anthropic", api_key) do
    {"https://api.anthropic.com/v1/models",
     [{"x-api-key", api_key}, {"anthropic-version", "2023-06-01"}]}
  end

  defp request_identity("openrouter", api_key) do
    {"https://openrouter.ai/api/v1/key", [{"authorization", "Bearer #{api_key}"}]}
  end

  defp transport_error(:timeout), do: :timeout

  defp transport_error(reason) when reason in [:closed, :econnrefused, :nxdomain],
    do: :network_error

  defp transport_error({:tls_alert, _detail}), do: :tls_error
  defp transport_error(_reason), do: :network_error
end
