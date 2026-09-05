defmodule Kodo.Test.ProviderHTTPPlug do
  @moduledoc false

  import Plug.Conn

  def init(agent), do: agent

  def call(conn, agent) do
    request = %{
      path: conn.request_path,
      authorization: get_req_header(conn, "authorization"),
      api_key: get_req_header(conn, "x-api-key")
    }

    response =
      Agent.get_and_update(agent, fn %{requests: requests, responses: [response | rest]} = state ->
        {response, %{state | requests: requests ++ [request], responses: rest}}
      end)

    conn =
      Enum.reduce(response[:headers] || [], conn, fn {name, value}, conn ->
        put_resp_header(conn, name, value)
      end)

    body = if is_binary(response.body), do: response.body, else: Jason.encode!(response.body)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(response.status, body)
  end
end
