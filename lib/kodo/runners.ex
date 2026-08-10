defmodule Kodo.Runners do
  @moduledoc """
  Owns durable runner identities and routes messages to the current local connection.

  PostgreSQL records identity and last-seen metadata; the unique Registry remains the source of
  truth for ephemeral online state so crashes cannot leave a stale connected flag.
  """

  import Ecto.Query

  alias Kodo.Repo
  alias Kodo.RunnerProtocol
  alias Kodo.Runners.Runner
  alias Kodo.Accounts.Scope

  @max_payload_bytes RunnerProtocol.max_payload_bytes()
  @runner_lifecycle_topic "runners"

  def subscribe_lifecycle do
    Phoenix.PubSub.subscribe(Kodo.PubSub, @runner_lifecycle_topic)
  end

  @doc "Returns a durable runner identity, whether or not it is currently connected."
  def get_runner(id), do: Repo.get(Runner, id)

  @doc "Routes one bounded request directly to the runner's unique live channel."
  def dispatch(runner_id, request) when is_map(request) do
    with {:ok, encoded} <- Jason.encode(request),
         true <- byte_size(encoded) <= @max_payload_bytes do
      case Registry.lookup(Kodo.RunnerRegistry, runner_id) do
        [{channel, _value}] ->
          send(channel, {:tool_request, request})
          :ok

        [] ->
          {:error, :offline}
      end
    else
      _ ->
        {:error, :invalid_request}
    end
  end

  @doc "Upserts mutable metadata while preserving the workspace's stable runner UUID."
  def register(%Scope{user: user}, attrs), do: do_register(attrs, user.id)
  def register(attrs), do: do_register(attrs, nil)

  defp do_register(attrs, user_id) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        workspace_root = attrs[:workspace_root] || attrs["workspace_root"]

        runner =
          if is_binary(workspace_root) do
            Runner
            |> where([runner], runner.workspace_root == ^workspace_root)
            |> lock("FOR UPDATE")
            |> Repo.one()
          end

        if runner && runner.user_id not in [nil, user_id] do
          Repo.rollback(:runner_not_authorized)
        else
          (runner || %Runner{})
          |> Runner.registration_changeset(attrs)
          |> Ecto.Changeset.put_change(:user_id, user_id || (runner && runner.user_id))
          |> Ecto.Changeset.put_change(:last_seen_at, now)
          |> persist_registration(runner)
        end
      end)

    broadcast_lifecycle(result, :runner_registered)
  end

  defp persist_registration(changeset, nil) do
    case Repo.insert(changeset) do
      {:ok, runner} -> runner
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp persist_registration(changeset, %Runner{}) do
    case Repo.update(changeset) do
      {:ok, runner} -> runner
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc "Records a successful authenticated channel join."
  def connected(%Runner{} = runner) do
    now = DateTime.utc_now()

    result =
      runner
      |> Ecto.Changeset.change(last_connected_at: now, last_seen_at: now)
      |> Repo.update()

    broadcast_lifecycle(result, :runner_connected)
  end

  @doc "Records response activity without persisting ephemeral channel state."
  def touch(id) do
    case get_runner(id) do
      nil -> {:error, :not_found}
      runner -> runner |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now()) |> Repo.update()
    end
  end

  defp broadcast_lifecycle({:ok, runner} = result, event) do
    Phoenix.PubSub.broadcast(Kodo.PubSub, @runner_lifecycle_topic, {event, runner})
    result
  end

  defp broadcast_lifecycle(error, _event), do: error
end
