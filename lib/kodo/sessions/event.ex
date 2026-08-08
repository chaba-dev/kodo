defmodule Kodo.Sessions.Event do
  @moduledoc "One immutable, ordered fact in a session's durable history."

  use Ecto.Schema
  import Ecto.Changeset

  @event_type_max_length 64
  @event_source_max_length 32
  @initial_event_version 1
  @minimum_positive_value 0
  @minimum_text_length 1

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "session_events" do
    field :sequence, :integer
    field :type, :string
    field :version, :integer, default: @initial_event_version
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
    |> validate_number(:sequence, greater_than: @minimum_positive_value)
    |> validate_number(:version, greater_than: @minimum_positive_value)
    |> validate_length(:type, min: @minimum_text_length, max: @event_type_max_length)
    |> validate_length(:source, min: @minimum_text_length, max: @event_source_max_length)
    |> foreign_key_constraint(:session_id)
    |> unique_constraint([:session_id, :sequence])
  end
end
