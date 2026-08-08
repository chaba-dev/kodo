defmodule Kodo.Sessions.Event do
  @moduledoc "One immutable, ordered fact in a session's durable history."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "session_events" do
    field :sequence, :integer
    field :type, :string
    field :version, :integer, default: 1
    field :payload, :map, default: %{}
    field :source, :string
    field :parent_id, :binary_id

    belongs_to :session, Kodo.Sessions.Session

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:session_id, :sequence, :type, :version, :payload, :source, :parent_id])
    |> validate_required([:session_id, :sequence, :type, :version, :payload, :source])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_number(:version, greater_than: 0)
    |> validate_length(:type, min: 1, max: 64)
    |> validate_length(:source, min: 1, max: 32)
    |> foreign_key_constraint(:session_id)
    |> unique_constraint([:session_id, :sequence])
  end
end
