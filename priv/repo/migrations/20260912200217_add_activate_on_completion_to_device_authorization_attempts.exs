defmodule Kodo.Repo.Migrations.AddActivateOnCompletionToDeviceAuthorizationAttempts do
  use Ecto.Migration

  def change do
    alter table(:device_authorization_attempts) do
      add :activate_on_completion, :boolean, null: false, default: false
    end
  end
end
