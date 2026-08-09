defmodule Kodo.Sessions.Session do
  @moduledoc "Durable identity and current index state for an agent session."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(idle running awaiting_approval completed failed cancelled)
  @approval_policies ~w(read-only safe standard)
  @display_name_max_length 255
  @minimum_text_length 1
  @first_event_sequence 1

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sessions" do
    field :title, :string
    field :status, :string, default: "idle"
    field :model, :string
    field :approval_policy, :string, default: "standard"
    field :next_event_sequence, :integer, default: @first_event_sequence

    belongs_to :runner, Kodo.Runners.Runner
    belongs_to :user, Kodo.Accounts.User, type: :id

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [:runner_id, :title, :model, :approval_policy])
    |> validate_required([:runner_id, :user_id, :title, :model, :approval_policy])
    |> validate_length(:title, min: @minimum_text_length, max: @display_name_max_length)
    |> validate_length(:model, min: @minimum_text_length, max: @display_name_max_length)
    |> validate_inclusion(:approval_policy, @approval_policies)
    |> foreign_key_constraint(:runner_id)
    |> foreign_key_constraint(:user_id)
  end

  def status_changeset(session, status) when status in @statuses do
    change(session, status: status)
  end
end
