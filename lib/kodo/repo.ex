defmodule Kodo.Repo do
  use Ecto.Repo,
    otp_app: :kodo,
    adapter: Ecto.Adapters.Postgres
end
