defmodule Kodo.Repo.Migrations.AddUserToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
    end

    create index(:sessions, [:user_id])
  end
end
