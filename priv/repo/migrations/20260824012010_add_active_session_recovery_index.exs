defmodule Kodo.Repo.Migrations.AddActiveSessionRecoveryIndex do
  use Ecto.Migration

  def change do
    create index(:sessions, [:status],
             name: :sessions_active_recovery_index,
             where: "status IN ('running', 'awaiting_approval')"
           )
  end
end
