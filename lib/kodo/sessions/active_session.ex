defmodule Kodo.Sessions.ActiveSession do
  @moduledoc "Supervised, disposable coordinator for one durable session."

  use GenServer

  alias Kodo.Sessions
  alias Kodo.Sessions.Projection

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  def child_spec(session_id) do
    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [session_id]},
      restart: :temporary
    }
  end

  def state(pid), do: GenServer.call(pid, :state)

  @impl true
  def init(session_id) do
    projection = session_id |> Sessions.events_after() |> Projection.from_events()
    {:ok, projection}
  end

  @impl true
  def handle_call(:state, _from, projection), do: {:reply, projection, projection}

  def via(session_id), do: {:via, Registry, {Kodo.SessionRegistry, session_id}}
end
