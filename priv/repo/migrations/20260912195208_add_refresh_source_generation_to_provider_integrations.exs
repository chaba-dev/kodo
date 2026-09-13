defmodule Kodo.Repo.Migrations.AddRefreshSourceGenerationToProviderIntegrations do
  use Ecto.Migration

  def change do
    alter table(:provider_integrations) do
      add :refresh_source_generation, :bigint
    end

    create constraint(
             :provider_integrations,
             :provider_integrations_refresh_source_generation_valid,
             check: "refresh_source_generation IS NULL OR refresh_source_generation >= 0"
           )
  end
end
