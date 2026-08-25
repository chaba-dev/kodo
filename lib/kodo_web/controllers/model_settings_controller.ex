defmodule KodoWeb.ModelSettingsController do
  @moduledoc "Authenticated API for role-specific user and repository model settings."

  use KodoWeb, :controller

  alias Kodo.Agent.ModelSettings

  def show(conn, params) do
    case ModelSettings.resolved(conn.assigns.current_scope, params["runner_id"]) do
      {:ok, mapping} -> json(conn, %{model_mapping: mapping})
      {:error, :runner_not_available} -> runner_not_available(conn)
    end
  end

  def put_user(conn, %{"role" => role} = params) do
    respond_to_put(
      conn,
      ModelSettings.put_user_override(conn.assigns.current_scope, role, params)
    )
  end

  def delete_user(conn, %{"role" => role}) do
    respond_to_delete(conn, ModelSettings.delete_user_override(conn.assigns.current_scope, role))
  end

  def put_repository(conn, %{"runner_id" => runner_id, "role" => role} = params) do
    respond_to_put(
      conn,
      ModelSettings.put_repository_override(conn.assigns.current_scope, runner_id, role, params)
    )
  end

  def delete_repository(conn, %{"runner_id" => runner_id, "role" => role}) do
    respond_to_delete(
      conn,
      ModelSettings.delete_repository_override(conn.assigns.current_scope, runner_id, role)
    )
  end

  defp respond_to_put(conn, {:ok, _override}) do
    conn |> put_status(:no_content) |> text("")
  end

  defp respond_to_put(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)})
  end

  defp respond_to_put(conn, {:error, :invalid_role}), do: invalid_role(conn)
  defp respond_to_put(conn, {:error, :runner_not_available}), do: runner_not_available(conn)

  defp respond_to_delete(conn, :ok), do: conn |> put_status(:no_content) |> text("")
  defp respond_to_delete(conn, {:error, :invalid_role}), do: invalid_role(conn)

  defp respond_to_delete(conn, {:error, :runner_not_available}),
    do: runner_not_available(conn)

  defp invalid_role(conn),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid role"})

  defp runner_not_available(conn),
    do: conn |> put_status(:forbidden) |> json(%{error: "runner is not available"})

  defp translate_error({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
