defmodule Kodo.Integrations.AuditEvent do
  @moduledoc "A credential-free record of a sensitive provider-integration action."

  use Ecto.Schema
  import Ecto.Changeset

  @event_types ~w(
    api_key_submitted
    api_key_replaced
    validation_succeeded
    validation_invalid
    validation_unavailable
    integration_disconnected
    oauth_succeeded
    refresh_succeeded
    refresh_invalid_grant
  )

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "integration_audit_events" do
    field :provider, :string
    field :event_type, :string
    field :credential_generation, :integer

    belongs_to :actor_user, Kodo.Accounts.User, type: :id
    belongs_to :integration, Kodo.Integrations.Integration

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:provider, :event_type, :credential_generation])
    |> validate_required([:provider, :event_type, :credential_generation])
    |> validate_inclusion(:event_type, @event_types)
    |> foreign_key_constraint(:actor_user_id)
    |> foreign_key_constraint(:integration_id)
  end
end
