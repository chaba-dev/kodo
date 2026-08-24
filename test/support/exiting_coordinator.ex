defmodule Kodo.Test.ExitingCoordinator do
  @moduledoc false

  use GenServer

  alias Kodo.Cluster.Discovery

  def start_link({session_id, owner}), do: GenServer.start_link(__MODULE__, {session_id, owner})

  def child_spec({session_id, _owner} = init_arg) do
    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [init_arg]},
      restart: :temporary
    }
  end

  @impl true
  def init({session_id, owner}) do
    :ok = Discovery.join_session(session_id)
    send(owner, {:exiting_coordinator_ready, self()})
    {:ok, owner}
  end

  @impl true
  def handle_call({:start_turn, _content, _client_request_id}, _from, owner) do
    send(owner, {:exiting_coordinator_called, self()})
    {:stop, :normal, owner}
  end
end
