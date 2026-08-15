defmodule KodoWeb.ClusterPlacementControllerTest do
  use KodoWeb.ConnCase

  alias Kodo.Cluster.Instances
  alias Kodo.Cluster.PlacementOverride

  import Kodo.AccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: authenticate_agent(conn, user), user: user}
  end

  test "creates an authenticated, audited, expiring rollback override", %{
    conn: conn,
    user: user
  } do
    {:ok, _older} = Instances.register(instance_attrs("older", 10))
    {:ok, _current} = Instances.register(instance_attrs("current", 11))

    response =
      conn
      |> post_json(~p"/api/cluster/placement-overrides", %{
        artifact_revision: "older",
        reason: "Current artifact is corrupt",
        expires_in_seconds: 600
      })
      |> json_response(201)

    assert response["override"]["artifact_revision"] == "older"
    assert response["override"]["reason"] == "Current artifact is corrupt"
    assert response["override"]["created_by_user_id"] == user.id

    override = Kodo.Repo.get!(PlacementOverride, response["override"]["id"])
    assert override.created_by_user_id == user.id
    assert DateTime.diff(override.expires_at, DateTime.utc_now(), :second) in 595..600
  end

  test "requires authentication and rejects unsafe or unavailable targets", %{conn: conn} do
    {:ok, _older} = Instances.register(instance_attrs("older", 10))
    {:ok, _current} = Instances.register(instance_attrs("current", 11))

    params = %{
      artifact_revision: "older",
      reason: "Rollback",
      expires_in_seconds: 600
    }

    assert build_conn()
           |> post_json(~p"/api/cluster/placement-overrides", params)
           |> json_response(401) == %{"error" => "authentication required"}

    assert conn
           |> post_json(~p"/api/cluster/placement-overrides", %{
             params
             | expires_in_seconds: 86_400
           })
           |> json_response(422)

    assert conn
           |> recycle(["accept", "authorization"])
           |> post_json(~p"/api/cluster/placement-overrides", %{
             params
             | artifact_revision: "missing"
           })
           |> json_response(409) == %{"error" => "target artifact is not available"}

    assert conn
           |> recycle(["accept", "authorization"])
           |> post_json(~p"/api/cluster/placement-overrides", %{
             params
             | artifact_revision: "current"
           })
           |> json_response(409) == %{"error" => "target artifact is not older"}
  end

  test "rejects a rollback target that cannot receive a rehomed coordinator", %{conn: conn} do
    {:ok, _legacy} =
      Instances.register(
        instance_attrs("legacy", 10)
        |> Map.put(:protocol_capabilities, [
          "session-events-v1",
          "session-ownership-v1",
          "session-placement-v1"
        ])
      )

    {:ok, _current} = Instances.register(instance_attrs("current", 11))

    assert conn
           |> post_json(~p"/api/cluster/placement-overrides", %{
             artifact_revision: "legacy",
             reason: "Must still support reverse handoff",
             expires_in_seconds: 600
           })
           |> json_response(409) == %{"error" => "target artifact is not available"}
  end

  defp instance_attrs(revision, generation) do
    %{
      boot_id: Ecto.UUID.generate(),
      node_name: Atom.to_string(node()),
      artifact_revision: revision,
      deployment_generation: generation,
      ready: true,
      draining: false,
      capacity: 2,
      protocol_capabilities: [
        "session-events-v1",
        "session-ownership-v1",
        "session-placement-v1",
        "session-rehoming-v1"
      ]
    }
  end

  defp post_json(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end
end
