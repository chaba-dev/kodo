defmodule Kodo.Agent.ModelSettings do
  @moduledoc "Persists and resolves user and repository role-model overrides."

  import Ecto.Query

  alias Kodo.Accounts.Scope
  alias Kodo.Agent.ModelMapping
  alias Kodo.Agent.RoleOverride
  alias Kodo.Repo
  alias Kodo.Runners.Runner

  def resolved(%Scope{} = scope, runner_id \\ nil) do
    with {:ok, layers} <- layers(scope, runner_id) do
      {:ok, ModelMapping.balanced(layers)}
    end
  end

  def layers(%Scope{user: user}, nil), do: {:ok, [{"user", override_map(user.id, nil)}]}

  def layers(%Scope{user: user}, runner_id) do
    with {:ok, runner} <- authorized_runner(user.id, runner_id) do
      {:ok, layers(user.id, runner.id)}
    end
  end

  def layers(user_id, runner_id) do
    [
      {"user", override_map(user_id, nil)},
      {"repository", override_map(user_id, runner_id)}
    ]
  end

  def put_user_override(%Scope{user: user}, role, attrs) do
    put_override(user.id, nil, role, attrs)
  end

  def put_repository_override(%Scope{user: user}, runner_id, role, attrs) do
    with {:ok, runner} <- authorized_runner(user.id, runner_id) do
      put_override(user.id, runner.id, role, attrs)
    end
  end

  def delete_user_override(%Scope{user: user}, role) do
    delete_override(user.id, nil, role)
  end

  def delete_repository_override(%Scope{user: user}, runner_id, role) do
    with {:ok, runner} <- authorized_runner(user.id, runner_id) do
      delete_override(user.id, runner.id, role)
    end
  end

  defp put_override(user_id, runner_id, role, attrs) do
    with {:ok, role} <- normalize_role(role) do
      Repo.transaction(fn -> persist_override_locked(user_id, runner_id, role, attrs) end)
      |> unwrap_transaction()
    end
  end

  defp persist_override_locked(user_id, runner_id, role, attrs) do
    override =
      RoleOverride
      |> where([override], override.user_id == ^user_id and override.role == ^role)
      |> matching_runner(runner_id)
      |> lock("FOR UPDATE")
      |> Repo.one() ||
        %RoleOverride{user_id: user_id, runner_id: runner_id, role: role}

    case override |> RoleOverride.changeset(attrs) |> persist_override(runner_id) do
      {:ok, override} -> override
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp delete_override(user_id, runner_id, role) do
    with {:ok, role} <- normalize_role(role) do
      RoleOverride
      |> where([override], override.user_id == ^user_id and override.role == ^role)
      |> matching_runner(runner_id)
      |> Repo.delete_all()

      :ok
    end
  end

  defp override_map(user_id, runner_id) do
    RoleOverride
    |> where([override], override.user_id == ^user_id)
    |> matching_runner(runner_id)
    |> Repo.all()
    |> Map.new(fn override ->
      {String.to_existing_atom(override.role), compact_mapping(override)}
    end)
  end

  defp compact_mapping(override) do
    %{model: override.model, reasoning: override.reasoning}
    |> Enum.reject(fn {_field, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp matching_runner(query, nil), do: where(query, [override], is_nil(override.runner_id))

  defp matching_runner(query, runner_id),
    do: where(query, [override], override.runner_id == ^runner_id)

  defp persist_override(%Ecto.Changeset{data: %{id: id}} = changeset, _runner_id)
       when not is_nil(id),
       do: Repo.update(changeset)

  defp persist_override(changeset, nil) do
    Repo.insert(changeset,
      on_conflict: {:replace, [:model, :reasoning, :updated_at]},
      conflict_target: {:unsafe_fragment, "(user_id, role) WHERE runner_id IS NULL"},
      returning: true
    )
  end

  defp persist_override(changeset, _runner_id) do
    Repo.insert(changeset,
      on_conflict: {:replace, [:model, :reasoning, :updated_at]},
      conflict_target:
        {:unsafe_fragment, "(user_id, runner_id, role) WHERE runner_id IS NOT NULL"},
      returning: true
    )
  end

  defp authorized_runner(user_id, runner_id) do
    case Ecto.UUID.cast(runner_id) do
      {:ok, runner_id} ->
        case Repo.get_by(Runner, id: runner_id, user_id: user_id) do
          nil -> {:error, :runner_not_available}
          runner -> {:ok, runner}
        end

      :error ->
        {:error, :runner_not_available}
    end
  end

  defp normalize_role(role) when is_atom(role), do: normalize_role(Atom.to_string(role))

  defp normalize_role(role) when role in ["primary", "search", "review"], do: {:ok, role}
  defp normalize_role(_role), do: {:error, :invalid_role}

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
