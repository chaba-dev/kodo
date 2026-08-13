defmodule Kodo.Cluster.Instance do
  @moduledoc """
  A durable record of one control-plane boot incarnation.

  Protocol capabilities describe clustered control-plane features. Runner transport compatibility
  remains defined by `Kodo.RunnerProtocol.version/0` rather than duplicated in this metadata.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @identity_max_length 255
  @max_capabilities 64
  @capability_max_length 128

  @primary_key {:boot_id, Ecto.UUID, autogenerate: false}

  schema "control_plane_instances" do
    field :node_name, :string
    field :artifact_revision, :string
    field :deployment_generation, :integer
    field :ready, :boolean, default: false
    field :draining, :boolean, default: false
    field :capacity, :integer
    field :protocol_capabilities, {:array, :string}, default: []
    field :last_seen_at, :utc_datetime_usec, read_after_writes: true

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def registration_changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :boot_id,
      :node_name,
      :artifact_revision,
      :deployment_generation,
      :ready,
      :draining,
      :capacity,
      :protocol_capabilities
    ])
    |> validate_required([
      :boot_id,
      :node_name,
      :artifact_revision,
      :deployment_generation,
      :ready,
      :draining,
      :capacity
    ])
    |> validate_length(:node_name, min: 1, max: @identity_max_length)
    |> validate_length(:artifact_revision, min: 1, max: @identity_max_length)
    |> validate_number(:deployment_generation, greater_than_or_equal_to: 0)
    |> validate_number(:capacity, greater_than: 0)
    |> validate_lifecycle()
    |> validate_capabilities()
    |> unique_constraint(:boot_id, name: :control_plane_instances_pkey)
    |> check_constraint(:node_name, name: :control_plane_instances_identity_not_empty)
    |> check_constraint(:ready, name: :control_plane_instances_lifecycle_valid)
    |> check_constraint(:protocol_capabilities,
      name: :control_plane_instances_capabilities_valid
    )
  end

  defp validate_lifecycle(changeset) do
    if get_field(changeset, :ready) and get_field(changeset, :draining) do
      add_error(changeset, :ready, "cannot be ready while draining")
    else
      changeset
    end
  end

  defp validate_capabilities(changeset) do
    validate_change(changeset, :protocol_capabilities, fn :protocol_capabilities, capabilities ->
      cond do
        length(capabilities) > @max_capabilities ->
          [protocol_capabilities: "has too many entries"]

        Enum.any?(
          capabilities,
          &(not is_binary(&1) or &1 == "" or byte_size(&1) > @capability_max_length)
        ) ->
          [
            protocol_capabilities:
              "entries must be non-empty strings of at most #{@capability_max_length} bytes"
          ]

        true ->
          []
      end
    end)
  end
end
