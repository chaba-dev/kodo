defmodule Kodo.Runners.Runner do
  use Ecto.Schema
  import Ecto.Changeset

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

    timestamps(type: :utc_datetime_usec)
  end

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
    |> validate_length(:workspace_root, min: 1, max: 1024)
    |> validate_length(:name, max: 255)
    |> validate_length(:platform, min: 1, max: 64)
    |> validate_length(:architecture, min: 1, max: 64)
    |> validate_length(:runner_version, min: 1, max: 64)
    |> validate_number(:protocol_version, equal_to: 2)
    |> validate_capabilities()
    |> unique_constraint(:workspace_root)
  end

  defp validate_capabilities(changeset) do
    validate_change(changeset, :capabilities, fn :capabilities, capabilities ->
      cond do
        length(capabilities) > 64 ->
          [capabilities: "has too many entries"]

        Enum.any?(capabilities, &(not is_binary(&1) or byte_size(&1) > 128 or &1 == "")) ->
          [capabilities: "entries must be non-empty strings of at most 128 bytes"]

        true ->
          []
      end
    end)
  end
end
