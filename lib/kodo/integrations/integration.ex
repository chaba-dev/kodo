defmodule Kodo.Integrations.Integration do
  @moduledoc "A user-owned provider integration with an opaque encrypted credential payload."

  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(openai openai_codex anthropic openrouter)
  @authentication_types ~w(api_key oauth)
  @connection_statuses ~w(disconnected connected reauthorization_required)
  @validation_statuses ~w(unverified valid invalid unavailable)
  @display_name_max_length 80
  @provider_names %{
    "openai" => "OpenAI API",
    "openai_codex" => "ChatGPT",
    "anthropic" => "Anthropic",
    "openrouter" => "OpenRouter"
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "provider_integrations" do
    field :provider, :string
    field :display_name, :string
    field :authentication_type, :string
    field :active, :boolean, default: false
    field :connection_status, :string, default: "disconnected"
    field :validation_status, :string, default: "unverified"
    field :encrypted_credentials, :binary, redact: true
    field :encryption_key_version, :string
    field :credential_format_version, :integer
    field :credential_generation, :integer, default: 0
    field :expires_at, :utc_datetime_usec
    field :validated_at, :utc_datetime_usec
    field :refreshed_at, :utc_datetime_usec
    field :validation_error_code, :string

    belongs_to :user, Kodo.Accounts.User, type: :id

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(integration, attrs) do
    integration
    |> cast(attrs, [:provider, :authentication_type, :display_name])
    |> put_default_display_name()
    |> validate_required([:provider, :authentication_type, :display_name])
    |> validate_length(:display_name, min: 1, max: @display_name_max_length)
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:authentication_type, @authentication_types)
    |> constraint_changeset()
  end

  @doc false
  def constraint_changeset(changeset) do
    changeset
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:provider, name: :provider_integrations_provider_valid)
    |> check_constraint(:authentication_type,
      name: :provider_integrations_authentication_type_valid
    )
    |> check_constraint(:authentication_type,
      name: :provider_integrations_provider_authentication_valid
    )
    |> check_constraint(:credential_generation,
      name: :provider_integrations_credential_generation_valid
    )
    |> check_constraint(:connection_status, name: :provider_integrations_state_valid)
    |> check_constraint(:active, name: :provider_integrations_active_connected)
    |> unique_constraint(:active, name: :provider_integrations_one_active_index)
  end

  def providers, do: @providers
  def authentication_types, do: @authentication_types
  def connection_statuses, do: @connection_statuses
  def validation_statuses, do: @validation_statuses
  def display_name_max_length, do: @display_name_max_length

  defp put_default_display_name(changeset) do
    if get_field(changeset, :display_name) do
      changeset
    else
      put_change(changeset, :display_name, @provider_names[get_field(changeset, :provider)])
    end
  end
end
