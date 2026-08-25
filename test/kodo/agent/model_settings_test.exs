defmodule Kodo.Agent.ModelSettingsTest do
  use Kodo.DataCase

  alias Kodo.Agent.ModelSettings
  alias Kodo.Runners
  alias Kodo.Sessions

  import Kodo.AccountsFixtures

  setup do
    scope = user_scope_fixture()
    {:ok, runner} = Runners.register(scope, runner_attrs())
    %{runner: runner, scope: scope}
  end

  test "repository settings override one user role while other recommendations are inherited", %{
    runner: runner,
    scope: scope
  } do
    assert {:ok, _override} =
             ModelSettings.put_user_override(scope, :search, %{
               model: "user:search",
               reasoning: "low"
             })

    assert {:ok, _override} =
             ModelSettings.put_repository_override(scope, runner.id, :search, %{
               model: "repository:search"
             })

    assert {:ok, mapping} = ModelSettings.resolved(scope, runner.id)
    search = mapping["roles"]["search"]

    assert search["model"] == "repository:search"
    assert search["reasoning"] == "low"
    assert search["sources"] == %{"model" => "repository", "reasoning" => "user"}
    assert mapping["roles"]["primary"]["sources"]["model"] == "profile"
    assert mapping["roles"]["review"]["sources"]["model"] == "profile"

    assert :ok = ModelSettings.delete_repository_override(scope, runner.id, :search)
    assert {:ok, reset} = ModelSettings.resolved(scope, runner.id)
    assert reset["roles"]["search"]["model"] == "user:search"
  end

  test "session creation snapshots resolved settings and keeps a temporary primary override", %{
    runner: runner,
    scope: scope
  } do
    assert {:ok, _override} =
             ModelSettings.put_user_override(scope, :review, %{model: "user:review"})

    assert {:ok, session} =
             Sessions.create_session(scope, %{
               runner_id: runner.id,
               title: "Mapped session",
               model: "session:primary"
             })

    mapping = hd(Sessions.events_after(session.id)).payload["model_mapping"]
    assert mapping["roles"]["primary"]["model"] == "session:primary"
    assert mapping["roles"]["primary"]["sources"]["model"] == "session"
    assert mapping["roles"]["review"]["model"] == "user:review"
    assert mapping["roles"]["review"]["sources"]["model"] == "user"
    assert mapping["roles"]["search"]["sources"]["model"] == "profile"
  end

  test "resolves user and repository layers from one database snapshot", %{
    runner: runner,
    scope: scope
  } do
    handler_id = "model-settings-query-count-#{System.unique_integer()}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:kodo, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if String.contains?(metadata.query, ~s(FROM "agent_role_overrides")) do
            send(parent, :override_query)
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _mapping} = ModelSettings.resolved(scope, runner.id)
    assert_receive :override_query
    refute_receive :override_query
  end

  test "partial updates preserve fields written by another request", %{scope: scope} do
    assert {:ok, _override} =
             ModelSettings.put_user_override(scope, :search, %{model: "user:search"})

    assert {:ok, _override} =
             ModelSettings.put_user_override(scope, :search, %{reasoning: "high"})

    assert {:ok, mapping} = ModelSettings.resolved(scope)
    assert mapping["roles"]["search"]["model"] == "user:search"
    assert mapping["roles"]["search"]["reasoning"] == "high"
  end

  test "rejects invalid roles, empty settings, and another user's repository", %{
    runner: runner,
    scope: scope
  } do
    assert {:error, :invalid_role} =
             ModelSettings.put_user_override(scope, "writer", %{model: "x"})

    assert {:error, changeset} = ModelSettings.put_user_override(scope, :search, %{})
    assert "or reasoning must be set" in errors_on(changeset).model

    other_scope = user_scope_fixture()

    assert {:error, :runner_not_available} =
             ModelSettings.put_repository_override(other_scope, runner.id, :search, %{model: "x"})
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
end
