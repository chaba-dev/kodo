defmodule Kodo.Repo.Migrations.AddRefreshRestoreActiveToProviderIntegrations do
  use Ecto.Migration

  def change do
    alter table(:provider_integrations) do
      add :refresh_restore_active, :boolean, null: false, default: false
    end
  end
end
