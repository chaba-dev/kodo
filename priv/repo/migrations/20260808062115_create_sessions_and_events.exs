defmodule Kodo.Repo.Migrations.CreateSessionsAndEvents do
  use Ecto.Migration

  @display_name_max_length 255
  @status_max_length 32
  @event_type_max_length 64
  @event_source_max_length 32
  @first_event_sequence 1
  @before_first_event_sequence 0
  @initial_event_version 1

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :runner_id, references(:runners, type: :binary_id, on_delete: :restrict), null: false
      add :title, :string, null: false, size: @display_name_max_length
      add :status, :string, null: false, size: @status_max_length
      add :model, :string, null: false, size: @display_name_max_length
      add :next_event_sequence, :bigint, null: false, default: @first_event_sequence

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sessions, [:runner_id])

    create constraint(:sessions, :sessions_next_event_sequence_positive,
             check: "next_event_sequence > #{@before_first_event_sequence}"
           )

    create table(:session_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sequence, :bigint, null: false
      add :type, :string, null: false, size: @event_type_max_length
      add :version, :integer, null: false, default: @initial_event_version
      add :payload, :map, null: false, default: %{}
      add :source, :string, null: false, size: @event_source_max_length
      add :parent_id, :binary_id
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:session_events, [:session_id, :sequence])
    create index(:session_events, [:session_id, :inserted_at])
  end
end
