defmodule Kodo.Integrations.CredentialKeyRing do
  @moduledoc "Blocks application readiness when credential key material is incomplete."

  import Ecto.Query

  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.DeviceAuthorizationAttempt
  alias Kodo.Integrations.Integration
  alias Kodo.Repo

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc false
  def start_link(_opts) do
    with :ok <- CredentialEncryption.validate_config(),
         :ok <- validate_referenced_versions() do
      :ignore
    end
  end

  @doc false
  def validate_referenced_versions do
    with {:ok, configured_versions} <- CredentialEncryption.configured_key_versions() do
      referenced_versions =
        Enum.uniq(
          referenced_versions(Integration) ++ referenced_versions(DeviceAuthorizationAttempt)
        )

      missing_versions = referenced_versions -- configured_versions

      if missing_versions == [] do
        :ok
      else
        {:error, {:credential_encryption_keys_missing, Enum.sort(missing_versions)}}
      end
    end
  end

  defp referenced_versions(schema) do
    schema
    |> where([record], not is_nil(record.encryption_key_version))
    |> select([record], record.encryption_key_version)
    |> distinct(true)
    |> Repo.all()
  end
end
