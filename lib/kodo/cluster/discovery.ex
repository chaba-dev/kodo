defmodule Kodo.Cluster.Discovery do
  @moduledoc """
  Provides advisory, cluster-wide discovery for live session and runner processes.

  Membership is intentionally ephemeral and eventually consistent. Callers must rely on
  PostgreSQL ownership epochs, runner authority leases, and durable events for correctness.
  """

  @scope Kodo.Cluster.Discovery.Scope
  @topic "cluster:discovery"

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {:pg, :start_link, [@scope]}
    }
  end

  def subscribe, do: Phoenix.PubSub.subscribe(Kodo.PubSub, @topic)

  def join_session(session_id, pid \\ self()),
    do: :pg.join(@scope, group(:session, session_id), pid)

  def join_runner(runner_id, pid \\ self()),
    do: :pg.join(@scope, group(:runner, runner_id), pid)

  def monitor_runner(runner_id), do: :pg.monitor(@scope, group(:runner, runner_id))
  def demonitor(ref), do: :pg.demonitor(@scope, ref)

  def session(session_id), do: member(:session, session_id)
  def runner(runner_id), do: member(:runner, runner_id)

  def members(kind, id) when kind in [:session, :runner],
    do: :pg.get_members(@scope, group(kind, id))

  def local_members(kind, id) when kind in [:session, :runner],
    do: :pg.get_local_members(@scope, group(kind, id))

  def scope, do: @scope
  def topic, do: @topic

  def group(kind, id) when kind in [:session, :runner], do: {kind, id}

  def parse_group({kind, id}) when kind in [:session, :runner], do: {:ok, kind, id}
  def parse_group(_group), do: :error

  defp member(kind, id) do
    case members(kind, id) do
      [] -> :error
      pids -> {:ok, Enum.min(pids)}
    end
  end
end
