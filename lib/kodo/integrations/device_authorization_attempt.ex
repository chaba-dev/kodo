defmodule Kodo.Integrations.DeviceAuthorizationAttempt do
  @moduledoc "Durable, user-owned state for one provider device authorization attempt."

  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(active completed cancelled expired failed)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "device_authorization_attempts" do
    field :provider, :string
    field :state, :string, default: "active"
    field :attempt_generation, :integer
    field :expected_integration_generation, :integer
    field :encrypted_payload, :binary, redact: true
    field :encryption_key_version, :string
    field :payload_format_version, :integer
    field :provider_deadline, :utc_datetime_usec
    field :polling_interval_ms, :integer
    field :next_poll_at, :utc_datetime_usec
    field :claim_owner_id, :binary_id
    field :claim_lease_expires_at, :utc_datetime_usec
    field :claim_epoch, :integer, default: 0
    field :terminal_error_code, :string

    belongs_to :user, Kodo.Accounts.User, type: :id
    belongs_to :integration, Kodo.Integrations.Integration

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :provider,
      :attempt_generation,
      :expected_integration_generation,
      :provider_deadline,
      :polling_interval_ms,
      :next_poll_at
    ])
    |> validate_required([
      :id,
      :user_id,
      :integration_id,
      :provider,
      :state,
      :attempt_generation,
      :expected_integration_generation,
      :encrypted_payload,
      :encryption_key_version,
      :payload_format_version,
      :provider_deadline,
      :polling_interval_ms,
      :next_poll_at,
      :claim_epoch
    ])
    |> validate_inclusion(:provider, ["openai_codex"])
    |> validate_inclusion(:state, @states)
    |> validate_number(:attempt_generation, greater_than: 0)
    |> validate_number(:expected_integration_generation, greater_than_or_equal_to: 0)
    |> validate_number(:polling_interval_ms,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 900_000
    )
    |> validate_number(:claim_epoch, greater_than_or_equal_to: 0)
    |> constraint_changeset()
  end

  @doc false
  def constraint_changeset(changeset) do
    changeset
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:integration_id,
      name: :device_attempts_integration_owner_provider_fkey
    )
    |> check_constraint(:provider, name: :device_attempts_provider_valid)
    |> check_constraint(:state, name: :device_attempts_state_valid)
    |> check_constraint(:attempt_generation, name: :device_attempts_generations_valid)
    |> check_constraint(:polling_interval_ms, name: :device_attempts_poll_interval_valid)
    |> check_constraint(:state, name: :device_attempts_payload_state_valid)
    |> check_constraint(:claim_owner_id, name: :device_attempts_claim_valid)
    |> check_constraint(:claim_epoch, name: :device_attempts_claim_epoch_valid)
    |> unique_constraint([:integration_id, :attempt_generation],
      name: :device_attempts_integration_generation_index
    )
    |> unique_constraint(:integration_id, name: :device_authorization_attempts_one_active_index)
  end

  def states, do: @states
end
