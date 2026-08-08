defmodule Kodo.Repo.Migrations.CreateSessionsAndEvents do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :runner_id, references(:runners, type: :binary_id, on_delete: :restrict), null: false
      add :title, :string, null: false, size: 255
      add :status, :string, null: false, size: 32
      add :model, :string, null: false, size: 255
      add :next_event_sequence, :bigint, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sessions, [:runner_id])

    create constraint(:sessions, :sessions_next_event_sequence_positive,
             check: "next_event_sequence > 0"
           )

    create table(:session_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sequence, :bigint, null: false
      add :type, :string, null: false, size: 64
      add :version, :integer, null: false, default: 1
      add :payload, :map, null: false, default: %{}
      add :source, :string, null: false, size: 32
      add :parent_id, :binary_id
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:session_events, [:session_id, :sequence])
    create index(:session_events, [:session_id, :inserted_at])
  end
end
