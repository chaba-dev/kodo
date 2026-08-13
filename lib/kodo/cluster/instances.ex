defmodule Kodo.Cluster.Instances do
  @moduledoc """
  Persists control-plane boot incarnations and their mutable lifecycle state.

  PostgreSQL's UTC clock is authoritative for liveness. Readiness means eligibility for session
  ownership; it does not represent HTTP endpoint health.
  """

  import Ecto.Query

  alias Kodo.Cluster.Instance
  alias Kodo.Repo

  @immutable_registration_fields [
    :node_name,
    :artifact_revision,
    :deployment_generation,
    :capacity,
    :protocol_capabilities
  ]

  def register(attrs) do
    %Instance{}
    |> Instance.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Registers a boot or restores that same boot after an ordinary supervisor restart."
  def register_current(attrs) do
    Repo.transaction(fn ->
      changeset = Instance.registration_changeset(%Instance{}, attrs)

      unless changeset.valid?, do: Repo.rollback(changeset)

      boot_id = Ecto.Changeset.get_field(changeset, :boot_id)

      case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:boot_id]) do
        {:ok, _instance} -> :ok
        {:error, changeset} -> Repo.rollback(changeset)
      end

      instance =
        Instance
        |> where([instance], instance.boot_id == ^boot_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      case instance do
        nil -> Repo.rollback(:instance_registration_lost)
        %Instance{} = instance -> resume_instance(instance, changeset)
      end
    end)
  end

  def get(boot_id), do: Repo.get(Instance, boot_id)

  def heartbeat(%Instance{} = instance) do
    Repo.transaction(fn -> heartbeat_locked(instance) end)
  end

  def begin_drain(%Instance{} = instance) do
    Repo.transaction(fn ->
      Instance
      |> where([record], record.boot_id == ^instance.boot_id)
      |> update([record],
        set: [
          ready: false,
          draining: true,
          last_seen_at: fragment("timezone('UTC', clock_timestamp())")
        ]
      )
      |> update_and_reload!(instance.boot_id)
    end)
  end

  @doc "Returns ready, non-draining instances whose database heartbeat is still fresh."
  def list_eligible(stale_after_seconds)
      when is_integer(stale_after_seconds) and stale_after_seconds >= 0 do
    Instance
    |> where(
      [instance],
      instance.ready and not instance.draining and
        fragment(
          "? >= timezone('UTC', clock_timestamp()) - (? * interval '1 second')",
          instance.last_seen_at,
          ^stale_after_seconds
        )
    )
    |> order_by([instance], asc: instance.boot_id)
    |> Repo.all()
  end

  defp resume_instance(instance, changeset) do
    if changeset.valid? and immutable_registration(changeset) == immutable_registration(instance) do
      if instance.draining do
        heartbeat_locked(instance)
      else
        Instance
        |> where([record], record.boot_id == ^instance.boot_id)
        |> update([record],
          set: [
            ready: true,
            draining: false,
            last_seen_at: fragment("timezone('UTC', clock_timestamp())")
          ]
        )
        |> update_and_reload!(instance.boot_id)
      end
    else
      Repo.rollback(:boot_identity_mismatch)
    end
  end

  defp heartbeat_locked(instance) do
    Instance
    |> where([record], record.boot_id == ^instance.boot_id)
    |> update([record],
      set: [last_seen_at: fragment("timezone('UTC', clock_timestamp())")]
    )
    |> update_and_reload!(instance.boot_id)
  end

  defp update_and_reload!(query, boot_id) do
    case Repo.update_all(query, []) do
      {1, nil} -> Repo.get!(Instance, boot_id)
      {0, nil} -> Repo.rollback(:instance_not_found)
    end
  end

  defp immutable_registration(%Ecto.Changeset{} = changeset) do
    Map.new(@immutable_registration_fields, &{&1, Ecto.Changeset.get_field(changeset, &1)})
  end

  defp immutable_registration(%Instance{} = instance) do
    Map.take(instance, @immutable_registration_fields)
  end
end
