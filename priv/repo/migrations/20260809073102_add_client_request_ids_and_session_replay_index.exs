defmodule Kodo.Repo.Migrations.AddClientRequestIdsAndSessionReplayIndex do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :client_request_id, :uuid
    end

    create unique_index(:sessions, [:user_id, :client_request_id],
             where: "client_request_id IS NOT NULL"
           )
  end
end
