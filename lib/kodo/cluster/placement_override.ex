defmodule Kodo.Cluster.PlacementOverride do
  @moduledoc "An authenticated, append-only audit record for temporary rollback placement."

  use Ecto.Schema
  import Ecto.Changeset

  @identity_max_length 255
  @reason_max_length 1_000
  @minimum_ttl_seconds 60
  @maximum_ttl_seconds 3_600

  schema "cluster_placement_overrides" do
    field :artifact_revision, :string
    field :reason, :string
    field :expires_at, :utc_datetime_usec
    field :expires_in_seconds, :integer, virtual: true
    belongs_to :created_by_user, Kodo.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(override, attrs) do
    override
    |> cast(attrs, [:artifact_revision, :reason, :expires_in_seconds])
    |> validate_required([:artifact_revision, :reason, :expires_in_seconds])
    |> update_change(:artifact_revision, &String.trim/1)
    |> update_change(:reason, &String.trim/1)
    |> validate_length(:artifact_revision, min: 1, max: @identity_max_length)
    |> validate_length(:reason, min: 1, max: @reason_max_length)
    |> validate_number(:expires_in_seconds,
      greater_than_or_equal_to: @minimum_ttl_seconds,
      less_than_or_equal_to: @maximum_ttl_seconds
    )
    |> check_constraint(:artifact_revision,
      name: :cluster_placement_overrides_values_not_empty
    )
  end
end
