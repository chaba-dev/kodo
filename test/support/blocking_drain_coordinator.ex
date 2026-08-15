defmodule Kodo.Test.BlockingDrainCoordinator do
  @moduledoc false

  use GenServer

  def start_link(id), do: GenServer.start_link(__MODULE__, id)

  def child_spec(id) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [id]},
      restart: :temporary
    }
  end

  @impl true
  def init(id), do: {:ok, id}

  @impl true
  def handle_call({:begin_drain, _owner_boot_id}, _from, state), do: {:noreply, state}
end
