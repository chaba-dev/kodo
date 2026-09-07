defmodule Kodo.Repo.Migrations.AllowMultipleProviderIntegrationsTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260907083117_allow_multiple_provider_integrations.exs"

  test "downgrade refuses ambiguous accounts instead of deleting data" do
    migration = File.read!(@migration_path)

    assert migration =~ "HAVING count(*) > 1"
    assert migration =~ "bool_or(connection_status = 'connected' AND NOT active)"
    assert migration =~ "cannot roll back multiple provider integrations"
    refute migration =~ ~r/DELETE\s+FROM\s+provider_integrations/i
  end
end
