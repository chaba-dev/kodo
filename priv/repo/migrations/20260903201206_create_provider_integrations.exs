defmodule Kodo.Repo.Migrations.CreateProviderIntegrations do
  use Ecto.Migration

  def change do
    create table(:provider_integrations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false, size: 32
      add :authentication_type, :string, null: false, size: 32
      add :connection_status, :string, null: false, size: 32, default: "disconnected"
      add :validation_status, :string, null: false, size: 32, default: "unverified"
      add :encrypted_credentials, :binary
      add :encryption_key_version, :string, size: 64
      add :credential_format_version, :integer
      add :credential_generation, :bigint, null: false, default: 0
      add :expires_at, :utc_datetime_usec
      add :validated_at, :utc_datetime_usec
      add :refreshed_at, :utc_datetime_usec
      add :validation_error_code, :string, size: 64

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:provider_integrations, [:user_id, :provider])

    create constraint(:provider_integrations, :provider_integrations_provider_valid,
             check: "provider IN ('openai', 'openai_codex', 'anthropic', 'openrouter')"
           )

    create constraint(:provider_integrations, :provider_integrations_authentication_type_valid,
             check: "authentication_type IN ('api_key', 'oauth')"
           )

    create constraint(
             :provider_integrations,
             :provider_integrations_provider_authentication_valid,
             check: """
             (provider = 'openai_codex' AND authentication_type = 'oauth') OR
             (provider IN ('openai', 'anthropic', 'openrouter') AND authentication_type = 'api_key')
             """
           )

    create constraint(:provider_integrations, :provider_integrations_credential_generation_valid,
             check: "credential_generation >= 0"
           )

    create constraint(:provider_integrations, :provider_integrations_state_valid,
             check: """
             (
               connection_status = 'disconnected' AND
               validation_status = 'unverified' AND
               encrypted_credentials IS NULL AND
               encryption_key_version IS NULL AND
               credential_format_version IS NULL AND
               expires_at IS NULL AND
               validated_at IS NULL AND
               refreshed_at IS NULL AND
               validation_error_code IS NULL
             ) OR (
               connection_status = 'connected' AND
               validation_status IN ('unverified', 'valid', 'invalid', 'unavailable') AND
               encrypted_credentials IS NOT NULL AND
               encryption_key_version IS NOT NULL AND
               credential_format_version IS NOT NULL
             ) OR (
               connection_status = 'reauthorization_required' AND
               validation_status = 'unverified' AND
               encrypted_credentials IS NOT NULL AND
               encryption_key_version IS NOT NULL AND
               credential_format_version IS NOT NULL
             )
             """
           )
  end
end
