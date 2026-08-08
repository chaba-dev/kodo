defmodule Kodo.Runners do
  @moduledoc """
  Owns durable runner identities and routes messages to the current local connection.

  PostgreSQL records identity and last-seen metadata; the unique Registry remains the source of
  truth for ephemeral online state so crashes cannot leave a stale connected flag.
  """

  alias Kodo.Repo
  alias Kodo.RunnerProtocol
  alias Kodo.Runners.Runner

  @max_payload_bytes RunnerProtocol.max_payload_bytes()

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
  def register(attrs) do
    now = DateTime.utc_now()

    %Runner{}
    |> Runner.registration_changeset(attrs)
    |> Ecto.Changeset.put_change(:last_seen_at, now)
    |> Repo.insert(
      conflict_target: :workspace_root,
      on_conflict: {:replace, registration_fields()},
      returning: true
    )
  end

  @doc "Records a successful authenticated channel join."
  def connected(%Runner{} = runner) do
    now = DateTime.utc_now()
    runner |> Ecto.Changeset.change(last_connected_at: now, last_seen_at: now) |> Repo.update()
  end

  @doc "Records response activity without persisting ephemeral channel state."
  def touch(id) do
    case get_runner(id) do
      nil -> {:error, :not_found}
      runner -> runner |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now()) |> Repo.update()
    end
  end

  defp registration_fields do
    [
      :name,
      :platform,
      :architecture,
      :runner_version,
      :protocol_version,
      :capabilities,
      :last_seen_at,
      :updated_at
    ]
  end
end
