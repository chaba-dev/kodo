defmodule Kodo.Repo.Migrations.CreateAgentRoleOverrides do
  use Ecto.Migration

  def change do
    create table(:agent_role_overrides, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :runner_id, references(:runners, type: :binary_id, on_delete: :delete_all)
      add :role, :string, null: false, size: 32
      add :model, :string, size: 255
      add :reasoning, :string, size: 32

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_role_overrides, [:user_id, :role],
             where: "runner_id IS NULL",
             name: :agent_role_overrides_user_role_index
           )

    create unique_index(:agent_role_overrides, [:user_id, :runner_id, :role],
             where: "runner_id IS NOT NULL",
             name: :agent_role_overrides_repository_role_index
           )

    create index(:agent_role_overrides, [:runner_id])

    create constraint(:agent_role_overrides, :agent_role_overrides_role_valid,
             check: "role IN ('primary', 'search', 'review')"
           )

    create constraint(:agent_role_overrides, :agent_role_overrides_mapping_present,
             check:
               "(model IS NOT NULL AND model <> '') OR (reasoning IS NOT NULL AND reasoning <> '')"
           )
  end
end
