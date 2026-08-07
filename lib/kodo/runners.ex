defmodule Kodo.Runners do
  @moduledoc "Durable runner identities and connection metadata."

  alias Kodo.Repo
  alias Kodo.Runners.Runner

  # Reserve room for the Phoenix topic/event envelope inside the 4 MiB wire-message limit.
  @max_payload_bytes 4 * 1024 * 1024 - 4096

  def get_runner(id), do: Repo.get(Runner, id)

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

  def connected(%Runner{} = runner) do
    now = DateTime.utc_now()
    runner |> Ecto.Changeset.change(last_connected_at: now, last_seen_at: now) |> Repo.update()
  end

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
