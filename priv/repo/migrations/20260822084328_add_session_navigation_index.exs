defmodule Kodo.Repo.Migrations.AddSessionNavigationIndex do
  use Ecto.Migration

  def change do
    create index(:sessions, [:user_id, "updated_at DESC", "id DESC"],
             name: :sessions_user_navigation_index
           )
  end
end
