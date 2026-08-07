defmodule Kodo.Repo.Migrations.CreateRunners do
  use Ecto.Migration

  def change do
    create table(:runners, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_root, :string, null: false, size: 1024
      add :name, :string, size: 255
      add :platform, :string, null: false, size: 64
      add :architecture, :string, null: false, size: 64
      add :runner_version, :string, null: false, size: 64
      add :protocol_version, :integer, null: false
      add :capabilities, {:array, :string}, null: false, default: []
      add :last_connected_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runners, [:workspace_root])
  end
end
