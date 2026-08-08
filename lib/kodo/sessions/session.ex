defmodule Kodo.Sessions.Session do
  @moduledoc "Durable identity and current index state for an agent session."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(idle running awaiting_approval completed failed cancelled)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sessions" do
    field :title, :string
    field :status, :string, default: "idle"
    field :model, :string
    field :next_event_sequence, :integer, default: 1

    belongs_to :runner, Kodo.Runners.Runner

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [:runner_id, :title, :model])
    |> validate_required([:runner_id, :title, :model])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_length(:model, min: 1, max: 255)
    |> foreign_key_constraint(:runner_id)
  end

  def status_changeset(session, status) when status in @statuses do
    change(session, status: status)
  end
end
