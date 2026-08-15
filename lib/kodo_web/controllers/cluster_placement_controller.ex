defmodule KodoWeb.ClusterPlacementController do
  @moduledoc "Authenticated control API for temporary cluster placement overrides."

  use KodoWeb, :controller

  alias Kodo.Cluster.Placement

  def create_override(conn, params) do
    case Placement.create_rollback_override(conn.assigns.current_scope, params) do
      {:ok, override} ->
        conn
        |> put_status(:created)
        |> json(%{
          override: %{
            id: override.id,
            artifact_revision: override.artifact_revision,
            reason: override.reason,
            expires_at: override.expires_at,
            created_by_user_id: override.created_by_user_id
          }
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors(changeset)})

      {:error, :target_unavailable} ->
        conn |> put_status(:conflict) |> json(%{error: "target artifact is not available"})

      {:error, :target_not_older} ->
        conn |> put_status(:conflict) |> json(%{error: "target artifact is not older"})
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
