defmodule Kodo.Cluster.Instances do
  @moduledoc """
  Persists control-plane boot incarnations and their mutable lifecycle state.

  PostgreSQL's UTC clock is authoritative for liveness. Readiness means eligibility for session
  ownership; it does not represent HTTP endpoint health.
  """

  import Ecto.Query

  alias Kodo.Cluster.Instance
  alias Kodo.ControlPlaneTelemetry
  alias Kodo.Repo

  @ownership_capability "session-ownership-v1"

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
        nil ->
          Repo.rollback(:instance_registration_lost)

        %Instance{} = instance ->
          instance = resume_instance(instance, changeset)
          retire_prior_boots(instance)
          instance
      end
    end)
  end

  def get(boot_id), do: Repo.get(Instance, boot_id)

  def heartbeat(%Instance{} = instance) do
    Repo.transaction(fn ->
      heartbeat_locked(instance, ControlPlaneTelemetry.repo_options(:instance_heartbeat))
    end)
  end

  def mark_ready(%Instance{} = instance) do
    Repo.transaction(fn ->
      query =
        Instance
        |> where([record], record.boot_id == ^instance.boot_id and not record.draining)
        |> update([record],
          set: [
            ready: true,
            last_seen_at: fragment("timezone('UTC', clock_timestamp())")
          ]
        )

      case Repo.update_all(query, []) do
        {1, nil} -> Repo.get!(Instance, instance.boot_id)
        {0, nil} -> Repo.rollback(:instance_draining_or_not_found)
      end
    end)
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

  @doc "Checks authoritative heartbeat liveness without conflating it with placement readiness."
  def alive?(boot_id, stale_after_seconds, opts \\ [])
      when is_integer(stale_after_seconds) and stale_after_seconds >= 0 do
    Repo.exists?(
      from(instance in Instance,
        where:
          instance.boot_id == ^boot_id and
            fragment(
              "? >= timezone('UTC', clock_timestamp()) - (? * interval '1 second')",
              instance.last_seen_at,
              ^stale_after_seconds
            )
      ),
      opts
    )
  end

  @doc "Requires the target and every currently eligible node to support ownership fencing."
  def ownership_supported_cluster_wide?(target_boot_id, stale_after_seconds)
      when is_integer(stale_after_seconds) and stale_after_seconds >= 0 do
    eligible = list_eligible(stale_after_seconds)

    Enum.any?(eligible, &(&1.boot_id == target_boot_id)) and
      Enum.all?(eligible, &(@ownership_capability in &1.protocol_capabilities))
  end

  def same_node?(left_boot_id, right_boot_id) do
    query =
      from(left in Instance,
        join: right in Instance,
        on: right.boot_id == ^right_boot_id,
        where: left.boot_id == ^left_boot_id,
        select: left.node_name == right.node_name
      )

    Repo.one(query) == true
  end

  defp resume_instance(instance, changeset) do
    if changeset.valid? and immutable_registration(changeset) == immutable_registration(instance) do
      if instance.draining do
        heartbeat_locked(instance)
      else
        ready = Ecto.Changeset.get_field(changeset, :ready)

        Instance
        |> where([record], record.boot_id == ^instance.boot_id)
        |> update([record],
          set: [
            ready: ^ready,
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

  defp retire_prior_boots(instance) do
    Instance
    |> where(
      [record],
      record.node_name == ^instance.node_name and record.boot_id != ^instance.boot_id
    )
    |> Repo.update_all(set: [ready: false])
  end

  defp heartbeat_locked(instance, opts \\ []) do
    Instance
    |> where([record], record.boot_id == ^instance.boot_id)
    |> update([record],
      set: [last_seen_at: fragment("timezone('UTC', clock_timestamp())")]
    )
    |> update_and_reload!(instance.boot_id, opts)
  end

  defp update_and_reload!(query, boot_id, opts \\ []) do
    case Repo.update_all(query, [], opts) do
      {1, nil} -> Repo.get!(Instance, boot_id, opts)
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
