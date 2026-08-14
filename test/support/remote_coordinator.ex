defmodule Kodo.Test.RemoteCoordinator do
  @moduledoc false

  def start(owner, discovery_scope, session_id) do
    spawn(fn ->
      :ok = :pg.join(discovery_scope, {:session, session_id}, self())
      loop(owner)
    end)
  end

  defp loop(owner) do
    receive do
      {:"$gen_call", from, :state} ->
        send(owner, {:remote_call_received, self()})

        receive do
          :reply -> GenServer.reply(from, :ok)
        end
    end
  end
end
