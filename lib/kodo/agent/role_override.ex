defmodule Kodo.Agent.RoleOverride do
  @moduledoc "A user or repository-specific override for one versioned agent role."

  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(primary search review)
  @model_max_length 255
  @reasoning_max_length 32

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_role_overrides" do
    field :role, :string
    field :model, :string
    field :reasoning, :string

    belongs_to :user, Kodo.Accounts.User, type: :id
    belongs_to :runner, Kodo.Runners.Runner

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(override, attrs) do
    override
    |> cast(attrs, [:model, :reasoning])
    |> validate_length(:model, min: 1, max: @model_max_length)
    |> validate_length(:reasoning, min: 1, max: @reasoning_max_length)
    |> validate_mapping_present()
  end

  def roles, do: @roles

  defp validate_mapping_present(changeset) do
    if get_field(changeset, :model) || get_field(changeset, :reasoning) do
      changeset
    else
      add_error(changeset, :model, "or reasoning must be set")
    end
  end
end
