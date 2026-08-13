defmodule Kodo.Repo.Migrations.AddSessionOwnershipEpochs do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :owner_boot_id,
          references(:control_plane_instances,
            column: :boot_id,
            type: :binary_id,
            on_delete: :restrict
          )

      add :ownership_epoch, :bigint, null: false, default: 0
    end

    create index(:sessions, [:owner_boot_id])

    create constraint(:sessions, :sessions_ownership_epoch_nonnegative,
             check: "ownership_epoch >= 0"
           )
  end
end
