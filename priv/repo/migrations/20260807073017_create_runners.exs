defmodule Kodo.Repo.Migrations.CreateRunners do
  use Ecto.Migration

  # Keep historical migrations self-contained while making the durable storage limits explicit.
  @workspace_root_max_length 1024
  @display_name_max_length 255
  @platform_field_max_length 64
  @version_field_max_length 64

  def change do
    create table(:runners, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_root, :string, null: false, size: @workspace_root_max_length
      add :name, :string, size: @display_name_max_length
      add :platform, :string, null: false, size: @platform_field_max_length
      add :architecture, :string, null: false, size: @platform_field_max_length
      add :runner_version, :string, null: false, size: @version_field_max_length
      add :protocol_version, :integer, null: false
      add :capabilities, {:array, :string}, null: false, default: []
      add :last_connected_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runners, [:workspace_root])
  end
end
