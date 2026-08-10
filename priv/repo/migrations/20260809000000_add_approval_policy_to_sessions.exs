defmodule Kodo.Repo.Migrations.AddApprovalPolicyToSessions do
  use Ecto.Migration

  @approval_policy_max_length 16

  def change do
    alter table(:sessions) do
      add :approval_policy, :string,
        null: false,
        default: "standard",
        size: @approval_policy_max_length
    end

    create constraint(:sessions, :sessions_approval_policy_allowed,
             check: "approval_policy IN ('read-only', 'safe', 'standard')"
           )
  end
end
