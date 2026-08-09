defmodule Kodo.Repo.Migrations.AddUserToRunners do
  use Ecto.Migration

  def change do
    alter table(:runners) do
      add :user_id, references(:users, on_delete: :nilify_all)
    end

    execute(
      """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1
          FROM sessions
          GROUP BY runner_id
          HAVING COUNT(DISTINCT user_id) > 1
        ) THEN
          RAISE EXCEPTION 'cannot assign runner ownership: historical sessions share a runner across users';
        END IF;
      END
      $$
      """,
      "SELECT 1"
    )

    execute(
      """
      UPDATE runners
      SET user_id = owners.user_id
      FROM (
        SELECT runner_id, MIN(user_id) AS user_id
        FROM sessions
        GROUP BY runner_id
      ) AS owners
      WHERE runners.id = owners.runner_id
      """,
      "UPDATE runners SET user_id = NULL"
    )

    create index(:runners, [:user_id])
  end
end
