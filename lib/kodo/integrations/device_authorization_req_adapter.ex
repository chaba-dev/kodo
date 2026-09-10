defmodule Kodo.Integrations.DeviceAuthorizationReqAdapter do
  @moduledoc """
  Req adapter for credential-bearing device authorization requests.

  It deliberately uses Mint directly: Finch telemetry includes request and
  response values, which are secrets throughout this protocol.
  """

  @default_timeout 10_000
  @max_response_bytes 64 * 1024

  def run(%Req.Request{} = request) do
    timeout = request.options[:device_authorization_timeout] || @default_timeout
    started_at = System.monotonic_time(:millisecond)

    task = Task.async(fn -> safe_perform(request, started_at, timeout) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {request, %Req.TransportError{reason: :timeout}}
    end
  end

  defp safe_perform(request, started_at, timeout) do
    perform(request, started_at, timeout)
  rescue
    _exception -> {request, %Req.TransportError{reason: :closed}}
  catch
    _kind, _reason -> {request, %Req.TransportError{reason: :closed}}
  end

  defp perform(
         %Req.Request{options: %{device_authorization_transport: transport}} = request,
         started_at,
         timeout
       )
       when is_function(transport, 3),
       do: transport.(request, started_at, timeout)

  defp perform(request, started_at, timeout) do
    url = request.url

    with {:ok, conn} <-
           Mint.HTTP.connect(:https, url.host, url.port || 443,
             mode: :passive,
             protocols: [:http1],
             transport_opts: [timeout: remaining(started_at, timeout)]
           ),
         {:ok, conn, ref} <-
           Mint.HTTP.request(
             conn,
             request.method |> to_string() |> String.upcase(),
             request_target(url),
             Req.Fields.get_list(request.headers),
             request.body
           ) do
      receive_response(request, conn, ref, started_at, timeout, empty_response())
    else
      {:error, reason} -> {request, %Req.TransportError{reason: safe_reason(reason)}}
    end
  end

  defp receive_response(request, conn, ref, started_at, timeout, response) do
    case Mint.HTTP.recv(conn, 0, remaining(started_at, timeout)) do
      {:ok, conn, entries} ->
        case collect(entries, ref, response) do
          {:cont, response} -> receive_response(request, conn, ref, started_at, timeout, response)
          {:done, response} -> close_response(request, conn, response)
          {:error, reason} -> close_error(request, conn, reason)
        end

      {:error, conn, reason, _entries} ->
        close_error(request, conn, reason)
    end
  end

  defp collect(entries, ref, response) do
    Enum.reduce_while(entries, {:cont, response}, fn
      {:status, ^ref, status}, {:cont, acc} -> {:cont, {:cont, %{acc | status: status}}}
      {:headers, ^ref, headers}, {:cont, acc} -> {:cont, {:cont, %{acc | headers: headers}}}
      {:data, ^ref, data}, {:cont, acc} -> add_data(acc, data)
      {:done, ^ref}, {:cont, acc} -> {:halt, {:done, acc}}
      {:error, ^ref, reason}, _acc -> {:halt, {:error, reason}}
      _entry, acc -> {:cont, acc}
    end)
  end

  defp add_data(response, data) do
    size = response.size + byte_size(data)

    if size <= @max_response_bytes,
      do: {:cont, {:cont, %{response | body: [data | response.body], size: size}}},
      else: {:halt, {:error, :response_too_large}}
  end

  defp close_response(request, conn, response) do
    _result = Mint.HTTP.close(conn)
    body = response.body |> Enum.reverse() |> IO.iodata_to_binary()
    {request, Req.Response.new(status: response.status, headers: response.headers, body: body)}
  end

  defp close_error(request, conn, reason) do
    _result = Mint.HTTP.close(conn)
    {request, %Req.TransportError{reason: safe_reason(reason)}}
  end

  defp remaining(started_at, timeout),
    do: max(timeout - (System.monotonic_time(:millisecond) - started_at), 0)

  @doc false
  def request_target(url) do
    # Build a fresh URI because URI.parse/1 retains a legacy authority field.
    # Mutating the absolute URI could therefore send `//host/path` to Mint.
    URI.to_string(%URI{path: url.path || "/", query: url.query})
  end

  defp safe_reason(:timeout), do: :timeout
  defp safe_reason(_reason), do: :closed

  defp empty_response, do: %{status: nil, headers: [], body: [], size: 0}
end
