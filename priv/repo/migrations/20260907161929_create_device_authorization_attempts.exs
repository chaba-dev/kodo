defmodule Kodo.Repo.Migrations.CreateDeviceAuthorizationAttempts do
  use Ecto.Migration

  def change do
    create table(:device_authorization_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :integration_id, :binary_id, null: false
      add :provider, :string, null: false, size: 32
      add :state, :string, null: false, size: 32, default: "active"
      add :attempt_generation, :bigint, null: false
      add :expected_integration_generation, :bigint, null: false
      add :encrypted_payload, :binary
      add :encryption_key_version, :string, size: 64
      add :payload_format_version, :integer
      add :provider_deadline, :utc_datetime_usec, null: false
      add :polling_interval_ms, :integer, null: false
      add :next_poll_at, :utc_datetime_usec, null: false
      add :claim_owner_id, :binary_id
      add :claim_lease_expires_at, :utc_datetime_usec
      add :claim_epoch, :bigint, null: false, default: 0
      add :terminal_error_code, :string, size: 64

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:device_authorization_attempts, [:integration_id, :attempt_generation],
             name: :device_attempts_integration_generation_index
           )

    create index(:device_authorization_attempts, [:user_id, :integration_id])
    create index(:device_authorization_attempts, [:state, :updated_at])

    create unique_index(:provider_integrations, [:id, :user_id, :provider],
             name: :provider_integrations_attempt_owner_identity_index
           )

    create unique_index(:device_authorization_attempts, [:integration_id],
             where: "state = 'active'",
             name: :device_authorization_attempts_one_active_index
           )

    create constraint(:device_authorization_attempts, :device_attempts_provider_valid,
             check: "provider = 'openai_codex'"
           )

    create constraint(:device_authorization_attempts, :device_attempts_state_valid,
             check: "state IN ('active', 'completed', 'cancelled', 'expired', 'failed')"
           )

    create constraint(:device_authorization_attempts, :device_attempts_generations_valid,
             check: "attempt_generation > 0 AND expected_integration_generation >= 0"
           )

    create constraint(:device_authorization_attempts, :device_attempts_poll_interval_valid,
             check: "polling_interval_ms >= 0 AND polling_interval_ms <= 900000"
           )

    create constraint(:device_authorization_attempts, :device_attempts_payload_state_valid,
             check: """
             (
               state = 'active' AND
               encrypted_payload IS NOT NULL AND
               encryption_key_version IS NOT NULL AND
               payload_format_version IS NOT NULL
             ) OR (
               state != 'active' AND
               encrypted_payload IS NULL AND
               encryption_key_version IS NULL AND
               payload_format_version IS NULL
             )
             """
           )

    create constraint(:device_authorization_attempts, :device_attempts_claim_valid,
             check: """
             (
               state = 'active' AND
               terminal_error_code IS NULL AND
               (
                 (claim_owner_id IS NULL AND claim_lease_expires_at IS NULL) OR
                 (claim_owner_id IS NOT NULL AND claim_lease_expires_at IS NOT NULL)
               )
             ) OR (
               state != 'active' AND
               claim_owner_id IS NULL AND
               claim_lease_expires_at IS NULL
             )
             """
           )

    create constraint(:device_authorization_attempts, :device_attempts_claim_epoch_valid,
             check: "claim_epoch >= 0"
           )

    execute(
      """
      ALTER TABLE device_authorization_attempts
      ADD CONSTRAINT device_attempts_integration_owner_provider_fkey
      FOREIGN KEY (integration_id, user_id, provider)
      REFERENCES provider_integrations (id, user_id, provider)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE device_authorization_attempts
      DROP CONSTRAINT device_attempts_integration_owner_provider_fkey
      """
    )
  end
end
