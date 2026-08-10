defmodule Kodo.Runners.Runner do
  @moduledoc "Durable identity and bounded capabilities reported by one local workspace runner."

  use Ecto.Schema
  import Ecto.Changeset

  alias Kodo.RunnerProtocol

  # These mirror the database varchar limits so invalid registration metadata fails predictably.
  @workspace_root_max_length 1024
  @display_name_max_length 255
  @platform_field_max_length 64
  @version_field_max_length 64
  @max_capabilities 64
  @capability_max_bytes 128
  @protocol_version RunnerProtocol.version()

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "runners" do
    field :workspace_root, :string
    field :name, :string
    field :platform, :string
    field :architecture, :string
    field :runner_version, :string
    field :protocol_version, :integer
    field :capabilities, {:array, :string}, default: []
    field :last_connected_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    belongs_to :user, Kodo.Accounts.User, type: :id

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Validates untrusted metadata received by the loopback registration endpoint."
  def registration_changeset(runner, attrs) do
    runner
    |> cast(attrs, [
      :workspace_root,
      :name,
      :platform,
      :architecture,
      :runner_version,
      :protocol_version,
      :capabilities,
      :last_seen_at
    ])
    |> validate_required([
      :workspace_root,
      :platform,
      :architecture,
      :runner_version,
      :protocol_version
    ])
    |> validate_length(:workspace_root, min: 1, max: @workspace_root_max_length)
    |> validate_length(:name, max: @display_name_max_length)
    |> validate_length(:platform, min: 1, max: @platform_field_max_length)
    |> validate_length(:architecture, min: 1, max: @platform_field_max_length)
    |> validate_length(:runner_version, min: 1, max: @version_field_max_length)
    |> validate_number(:protocol_version, equal_to: @protocol_version)
    |> validate_capabilities()
    |> unique_constraint(:workspace_root)
  end

  defp validate_capabilities(changeset) do
    validate_change(changeset, :capabilities, fn :capabilities, capabilities ->
      cond do
        length(capabilities) > @max_capabilities ->
          [capabilities: "has too many entries"]

        Enum.any?(
          capabilities,
          &(not is_binary(&1) or byte_size(&1) > @capability_max_bytes or &1 == "")
        ) ->
          [
            capabilities:
              "entries must be non-empty strings of at most #{@capability_max_bytes} bytes"
          ]

        true ->
          []
      end
    end)
  end
end
