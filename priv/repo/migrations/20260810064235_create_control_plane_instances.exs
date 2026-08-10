defmodule Kodo.Repo.Migrations.CreateControlPlaneInstances do
  use Ecto.Migration

  @identity_max_length 255
  @capability_max_length 128
  @max_capabilities 64
  @minimum_capacity 1
  @minimum_generation 0

  def change do
    create table(:control_plane_instances, primary_key: false) do
      add :boot_id, :binary_id, primary_key: true
      add :node_name, :string, null: false, size: @identity_max_length
      add :artifact_revision, :string, null: false, size: @identity_max_length
      add :deployment_generation, :bigint, null: false
      add :ready, :boolean, null: false, default: false
      add :draining, :boolean, null: false, default: false
      add :capacity, :integer, null: false

      add :protocol_capabilities, {:array, :string},
        null: false,
        default: [],
        size: @capability_max_length

      add :last_seen_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('UTC', clock_timestamp())")

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:control_plane_instances, [
             :deployment_generation,
             :artifact_revision,
             :ready,
             :draining
           ])

    create index(:control_plane_instances, [:last_seen_at])

    create constraint(:control_plane_instances, :control_plane_instances_capacity_positive,
             check: "capacity >= #{@minimum_capacity}"
           )

    create constraint(
             :control_plane_instances,
             :control_plane_instances_generation_nonnegative,
             check: "deployment_generation >= #{@minimum_generation}"
           )

    create constraint(:control_plane_instances, :control_plane_instances_identity_not_empty,
             check: "char_length(node_name) > 0 AND char_length(artifact_revision) > 0"
           )

    create constraint(:control_plane_instances, :control_plane_instances_lifecycle_valid,
             check: "NOT (ready AND draining)"
           )

    create constraint(:control_plane_instances, :control_plane_instances_capabilities_valid,
             check:
               "cardinality(protocol_capabilities) <= #{@max_capabilities} AND " <>
                 "array_position(protocol_capabilities, NULL) IS NULL AND " <>
                 "array_position(protocol_capabilities, '') IS NULL"
           )
  end
end
