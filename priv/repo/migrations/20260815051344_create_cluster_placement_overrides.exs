defmodule Kodo.Repo.Migrations.CreateClusterPlacementOverrides do
  use Ecto.Migration

  @identity_max_length 255
  @reason_max_length 1_000

  def change do
    create table(:cluster_placement_overrides) do
      add :artifact_revision, :string, null: false, size: @identity_max_length
      add :reason, :string, null: false, size: @reason_max_length
      add :expires_at, :utc_datetime_usec, null: false
      add :created_by_user_id, references(:users, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:cluster_placement_overrides, [:expires_at, :inserted_at])
    create index(:cluster_placement_overrides, [:created_by_user_id])

    create constraint(
             :cluster_placement_overrides,
             :cluster_placement_overrides_values_not_empty,
             check: "char_length(artifact_revision) > 0 AND char_length(reason) > 0"
           )
  end
end
