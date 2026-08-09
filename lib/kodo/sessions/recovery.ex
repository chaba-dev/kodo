defmodule Kodo.Sessions.Recovery do
  @moduledoc "Synchronously restores durable active-session coordinators during application startup."

  use GenServer

  alias Kodo.Sessions

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def recover_active_sessions do
    Enum.each(Sessions.list_active_sessions(), fn session ->
      {:ok, _pid} = Sessions.ensure_started(session.id)
    end)
  end

  @impl true
  def init(_opts) do
    recover_active_sessions()

    {:ok, %{}}
  end
end
