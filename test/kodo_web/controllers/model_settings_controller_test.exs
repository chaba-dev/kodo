defmodule KodoWeb.ModelSettingsControllerTest do
  use KodoWeb.ConnCase

  alias Kodo.Integrations
  alias Kodo.Runners

  import Kodo.AccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    scope = Kodo.Accounts.Scope.for_user(user)
    {:ok, runner} = Runners.register(scope, runner_attrs())
    %{conn: authenticate_agent(conn, user), runner: runner, scope: scope}
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

  test "reports provider-specific connection and billing feedback for every role", %{
    conn: conn,
    scope: scope
  } do
    assert {:ok, anthropic} =
             Integrations.connect(scope, "anthropic", "api_key", %{"api_key" => "secret"})

    assert {:ok, _invalid} =
             Integrations.validation_invalid(
               scope,
               anthropic.id,
               anthropic.credential_generation
             )

    assert {:ok, _override} =
             Kodo.Agent.ModelSettings.put_user_override(scope, :search, %{
               model: "anthropic:claude-3-5-haiku-latest"
             })

    assert {:ok, _override} =
             Kodo.Agent.ModelSettings.put_user_override(scope, :review, %{
               model: "openrouter:anthropic/claude-sonnet-4"
             })

    response =
      conn
      |> get(~p"/api/model-settings")
      |> json_response(200)

    assert response["integration_feedback"]["primary"] == %{
             "provider" => "openai",
             "provider_name" => "OpenAI API",
             "billing_path" => "platform",
             "status" => "not_connected",
             "settings_path" => "/integrations?provider=openai&action=connect"
           }

    assert response["integration_feedback"]["search"] == %{
             "provider" => "anthropic",
             "provider_name" => "Anthropic",
             "billing_path" => "platform",
             "status" => "invalid",
             "settings_path" => "/integrations?provider=anthropic&action=replace"
           }

    assert response["integration_feedback"]["review"] == %{
             "provider" => "openrouter",
             "provider_name" => "OpenRouter",
             "billing_path" => "aggregator",
             "status" => "not_connected",
             "settings_path" => "/integrations?provider=openrouter&action=connect"
           }
  end

  defp runner_attrs do
    %{
      workspace_root: "/work/#{Ecto.UUID.generate()}",
      platform: "linux",
      architecture: "x86_64",
      runner_version: "0.1.0",
      protocol_version: 5,
      capabilities: []
    }
  end

  defp put_json(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put(path, Jason.encode!(params))
  end
end
