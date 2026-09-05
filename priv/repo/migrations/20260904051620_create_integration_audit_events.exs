defmodule Kodo.Repo.Migrations.CreateIntegrationAuditEvents do
  use Ecto.Migration

  def change do
    create table(:integration_audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :actor_user_id, references(:users, on_delete: :delete_all), null: false

      add :integration_id,
          references(:provider_integrations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :provider, :string, null: false, size: 32
      add :event_type, :string, null: false, size: 64
      add :credential_generation, :bigint, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:integration_audit_events, [:actor_user_id, :inserted_at])
    create index(:integration_audit_events, [:integration_id, :inserted_at])
  end
end
