defmodule Kodo.Repo.Migrations.AddUserToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      # Existing single-user sessions remain unowned; newly created sessions always set this field.
      add :user_id, references(:users, on_delete: :delete_all)
    end

    create index(:sessions, [:user_id])
  end
end
