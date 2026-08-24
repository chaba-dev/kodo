defmodule Kodo.Test.RecoveryRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :kodo,
    adapter: Ecto.Adapters.Postgres
end
