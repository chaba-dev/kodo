defmodule KodoWeb.RunnerRegistrationControllerTest do
  use KodoWeb.ConnCase

  @valid %{
    workspace_root: "/work/project",
    platform: "linux",
    architecture: "x86_64",
    runner_version: "0.1.0",
    protocol_version: 3,
    capabilities: ["shell"]
  }

  test "loopback registration returns socket credentials", %{conn: conn} do
    response = conn |> post_json(@valid) |> json_response(200)

    assert response["runner_id"]
    assert response["token"]
    assert response["token_expires_in"] == 86_400
    assert response["socket_path"] == "/runner/websocket"
    assert response["topic"] == "runner:#{response["runner_id"]}"
    assert response["protocol_version"] == 3
  end

  test "registration rejects non-loopback clients", %{conn: conn} do
    conn = %{conn | remote_ip: {192, 0, 2, 10}}
    assert conn |> post_json(@valid) |> json_response(403)
  end

  test "registration rejects browser form bodies", %{conn: conn} do
    assert conn |> post(~p"/api/runners", @valid) |> json_response(415)
  end

  defp post_json(conn, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/runners", Jason.encode!(params))
  end
end
