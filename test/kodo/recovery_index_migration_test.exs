defmodule Kodo.RecoveryIndexMigrationTest do
  use ExUnit.Case, async: true

  @migration Kodo.Repo.Migrations.AddActiveSessionRecoveryIndex
  @migration_path "priv/repo/migrations/20260824012010_add_active_session_recovery_index.exs"

  test "creates the recovery index concurrently outside a DDL transaction" do
    Code.require_file(@migration_path)

    assert @migration.__migration__()[:disable_ddl_transaction]
    assert @migration.__migration__()[:disable_migration_lock]
    assert File.read!(@migration_path) =~ "concurrently: true"
  end
end
