defmodule KodoWeb.ModelSettingsControllerTest do
  use KodoWeb.ConnCase

  alias Kodo.Runners

  import Kodo.AccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    scope = Kodo.Accounts.Scope.for_user(user)
    {:ok, runner} = Runners.register(scope, runner_attrs())
    %{conn: authenticate_agent(conn, user), runner: runner}
  end

  test "sets, resolves, and clears layered role settings", %{conn: conn, runner: runner} do
    assert conn
           |> put_json(~p"/api/model-settings/roles/search", %{
             model: "user:search",
             reasoning: "low"
           })
           |> response(204)

    assert conn
           |> recycle(["accept", "authorization"])
           |> put_json(~p"/api/model-settings/repositories/#{runner.id}/roles/search", %{
             model: "repository:search"
           })
           |> response(204)

    mapping =
      conn
      |> recycle(["accept", "authorization"])
      |> get(~p"/api/model-settings?runner_id=#{runner.id}")
      |> json_response(200)
      |> Map.fetch!("model_mapping")

    assert mapping["roles"]["search"]["model"] == "repository:search"
    assert mapping["roles"]["search"]["reasoning"] == "low"
    assert mapping["roles"]["primary"]["sources"]["model"] == "profile"

    assert conn
           |> recycle(["accept", "authorization"])
           |> delete(~p"/api/model-settings/repositories/#{runner.id}/roles/search")
           |> response(204)
  end

  test "rejects invalid settings and inaccessible repositories", %{conn: conn} do
    assert conn
           |> put_json(~p"/api/model-settings/roles/writer", %{model: "test:model"})
           |> json_response(422) == %{"error" => "invalid role"}

    assert conn
           |> recycle(["accept", "authorization"])
           |> put_json(~p"/api/model-settings/roles/search", %{})
           |> json_response(422)

    assert conn
           |> recycle(["accept", "authorization"])
           |> get(~p"/api/model-settings?runner_id=#{Ecto.UUID.generate()}")
           |> json_response(403) == %{"error" => "runner is not available"}
  end

  defp runner_attrs do
    %{
      workspace_root: "/work/#{Ecto.UUID.generate()}",
      platform: "linux",
      architecture: "x86_64",
      runner_version: "0.1.0",
      protocol_version: 4,
      capabilities: []
    }
  end

  defp put_json(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put(path, Jason.encode!(params))
  end
end
