defmodule Kodo.Repo.Migrations.AddRefreshClaimToProviderIntegrations do
  use Ecto.Migration

  def change do
    alter table(:provider_integrations) do
      add :refresh_claim_owner_id, :binary_id
      add :refresh_claim_epoch, :bigint, null: false, default: 0
      add :refresh_claim_generation, :bigint
      add :refresh_lease_expires_at, :utc_datetime_usec
    end

    create index(:provider_integrations, [:refresh_lease_expires_at],
             where: "refresh_claim_owner_id IS NOT NULL",
             name: :provider_integrations_refresh_lease_index
           )

    create constraint(:provider_integrations, :provider_integrations_refresh_claim_epoch_valid,
             check: "refresh_claim_epoch >= 0"
           )

    create constraint(:provider_integrations, :provider_integrations_refresh_claim_valid,
             check: """
             (
               refresh_claim_owner_id IS NULL AND
               refresh_claim_generation IS NULL AND
               refresh_lease_expires_at IS NULL
             ) OR (
               refresh_claim_owner_id IS NOT NULL AND
               refresh_claim_generation IS NOT NULL AND
               refresh_claim_generation >= 0 AND
               refresh_lease_expires_at IS NOT NULL
             )
             """
           )
  end
end
