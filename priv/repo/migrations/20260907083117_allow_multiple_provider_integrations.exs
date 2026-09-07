defmodule Kodo.Repo.Migrations.AllowMultipleProviderIntegrations do
  use Ecto.Migration

  def up do
    alter table(:provider_integrations) do
      add :display_name, :string, size: 80
      add :active, :boolean, null: false, default: false
    end

    execute("""
    UPDATE provider_integrations
    SET display_name = CASE provider
      WHEN 'openai' THEN 'OpenAI API'
      WHEN 'openai_codex' THEN 'ChatGPT'
      WHEN 'anthropic' THEN 'Anthropic'
      WHEN 'openrouter' THEN 'OpenRouter'
    END,
    active = connection_status = 'connected'
    """)

    alter table(:provider_integrations) do
      modify :display_name, :string, null: false, size: 80
    end

    drop unique_index(:provider_integrations, [:user_id, :provider])
    create index(:provider_integrations, [:user_id, :provider])

    create unique_index(:provider_integrations, [:user_id, :provider],
             where: "active",
             name: :provider_integrations_one_active_index
           )

    create constraint(:provider_integrations, :provider_integrations_active_connected,
             check: "NOT active OR connection_status = 'connected'"
           )
  end

  def down do
    drop constraint(:provider_integrations, :provider_integrations_active_connected)

    drop index(:provider_integrations, [:user_id, :provider],
           name: :provider_integrations_one_active_index
         )

    drop index(:provider_integrations, [:user_id, :provider])

    # A rollback can preserve only one account per provider.
    execute("""
    DELETE FROM provider_integrations duplicate
    USING provider_integrations retained
    WHERE duplicate.user_id = retained.user_id
      AND duplicate.provider = retained.provider
      AND (
        (retained.active AND NOT duplicate.active) OR
        (retained.active = duplicate.active AND retained.inserted_at < duplicate.inserted_at) OR
        (retained.active = duplicate.active AND retained.inserted_at = duplicate.inserted_at AND retained.id < duplicate.id)
      )
    """)

    create unique_index(:provider_integrations, [:user_id, :provider])

    alter table(:provider_integrations) do
      remove :active
      remove :display_name
    end
  end
end
