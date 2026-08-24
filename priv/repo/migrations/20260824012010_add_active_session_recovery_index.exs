defmodule Kodo.Repo.Migrations.AddActiveSessionRecoveryIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:sessions, [:status],
             concurrently: true,
             name: :sessions_active_recovery_index,
             where: "status IN ('running', 'awaiting_approval')"
           )
  end
end
