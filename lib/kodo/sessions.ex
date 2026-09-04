defmodule Kodo.Sessions do
  @moduledoc "Creates sessions and owns their immutable, monotonically ordered event logs."

  import Ecto.Query

  alias Kodo.Accounts.Scope
  alias Kodo.Cluster.Discovery
  alias Kodo.Cluster.InstanceManager
  alias Kodo.Cluster.Instances
  alias Kodo.Cluster.Placement
  alias Kodo.ControlPlaneTelemetry
  alias Kodo.Agent.ModelSettings
  alias Kodo.Accounts.User
  alias Kodo.Repo
  alias Kodo.Sessions.Event
  alias Kodo.Sessions.Ownership
  alias Kodo.Sessions.Projection
  alias Kodo.Sessions.Session
  alias Kodo.Runners.Runner

  @before_first_event_sequence 0
  @initial_event_version 1
  @single_event_increment 1
  @single_updated_row 1
  @placement_attempts 3
  @capacity_statuses ["idle", "running", "awaiting_approval"]
  @stale_coordinator_shutdown_timeout 5_000
  @ownership_lock_sql "SELECT pg_advisory_lock(hashtextextended($1, 0))"
  @ownership_unlock_sql "SELECT pg_advisory_unlock(hashtextextended($1, 0))"
  @session_index_topic_prefix "session_index:"
  @session_index_event_types ["session_created", "session_status_changed", "session_cancelled"]
  @default_session_page_size 50
  @timeline_anchor_types ["user_message", "assistant_message_completed", "tool_requested"]
  @timeline_tool_types ["tool_requested", "tool_started", "tool_completed", "tool_failed"]
  @default_timeline_page_size 50

  @ownership_stale_after_seconds Application.compile_env!(
                                   :kodo,
                                   [Kodo.Cluster.InstanceManager, :ownership_stale_after_seconds]
                                 )

  def get_session(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(Session, id)
      :error -> nil
    end
  end

  def get_session(%Scope{user: user}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(Session, id: id, user_id: user.id)
      :error -> nil
    end
  end

  def get_session!(id), do: Repo.get!(Session, id)

  @doc false
  def owner_scope(session_id) do
    case Ecto.UUID.cast(session_id) do
      {:ok, session_id} ->
        user =
          User
          |> join(:inner, [user], session in Session, on: session.user_id == user.id)
          |> where([_user, session], session.id == ^session_id)
          |> Repo.one()

        if user, do: {:ok, Scope.for_user(user)}, else: {:error, :session_not_found}

      :error ->
        {:error, :session_not_found}
    end
  end

  def list_sessions(%Scope{user: user}) do
    Session
    |> where([session], session.user_id == ^user.id)
    |> order_by([session], desc: session.updated_at)
    |> preload(:runner)
    |> Repo.all()
  end

  def list_sessions_page(%Scope{user: user}, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_session_page_size)

    sessions =
      Session
      |> where([session], session.user_id == ^user.id)
      |> before_cursor(Keyword.get(opts, :before))
      |> order_by([session], desc: session.updated_at, desc: session.id)
      |> limit(^(limit + 1))
      |> preload(:runner)
      |> Repo.all()

    page = Enum.take(sessions, limit)
    cursor = if length(sessions) > limit, do: session_cursor(List.last(page))
    {page, cursor}
  end

  def get_session_for_index(%Scope{} = scope, session_id) do
    opts = ControlPlaneTelemetry.repo_options(:session_index_refresh)

    session =
      case Ecto.UUID.cast(session_id) do
        {:ok, session_id} ->
          Session
          |> where([session], session.id == ^session_id and session.user_id == ^scope.user.id)
          |> Repo.one(opts)

        :error ->
          nil
      end

    case session do
      nil -> nil
      session -> Repo.preload(session, :runner, opts)
    end
  end

  def subscribe_index(%Scope{user: user}) do
    Phoenix.PubSub.subscribe(Kodo.PubSub, session_index_topic(user.id))
  end

  def timeline_page(%Scope{user: user}, session_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_timeline_page_size)

    anchors =
      Event
      |> join(:inner, [event], session in assoc(event, :session))
      |> where(
        [event, session],
        event.session_id == ^session_id and session.user_id == ^user.id and
          event.type in @timeline_anchor_types
      )
      |> before_event_sequence(Keyword.get(opts, :before_sequence))
      |> order_by([event], desc: event.sequence)
      |> limit(^(limit + 1))
      |> Repo.all()

    page = Enum.take(anchors, limit)
    events = Enum.reverse(page)

    tool_call_ids =
      for %{type: "tool_requested", payload: %{"tool_call_id" => tool_call_id}} <- events,
          do: tool_call_id

    tool_calls = visible_tool_calls(user.id, session_id, tool_call_ids)
    before_sequence = if length(anchors) > limit, do: hd(events).sequence

    %{events: events, tool_calls: tool_calls, before_sequence: before_sequence}
  end

  def pending_approval_event(%Scope{user: user}, session_id) do
    Event
    |> join(:inner, [event], session in assoc(event, :session))
    |> where(
      [event, session],
      event.session_id == ^session_id and session.user_id == ^user.id and
        event.type == "approval_requested"
    )
    |> order_by([event], desc: event.sequence)
    |> limit(1)
    |> Repo.one()
  end

  def latest_completed_tool_event(%Scope{user: user}, session_id, name) do
    Event
    |> join(:inner, [event], session in assoc(event, :session))
    |> where(
      [event, session],
      event.session_id == ^session_id and session.user_id == ^user.id and
        event.type == "tool_completed" and
        fragment("?->>'name'", event.payload) == ^name
    )
    |> order_by([event], desc: event.sequence)
    |> limit(1)
    |> Repo.one()
  end

  def latest_event_sequence(%Scope{user: user}, session_id) do
    Event
    |> join(:inner, [event], session in assoc(event, :session))
    |> where([event, session], event.session_id == ^session_id and session.user_id == ^user.id)
    |> select([event], coalesce(max(event.sequence), @before_first_event_sequence))
    |> Repo.one()
  end

  def list_active_sessions do
    Session
    |> where([session], session.status in ["running", "awaiting_approval"])
    |> Repo.all(ControlPlaneTelemetry.repo_options(:recovery_discovery))
  end

  @doc "Claims an unowned session or replaces a coordinator from this node or a stale owner."
  def claim_ownership(session_id, owner_boot_id) do
    with_placement_locks(session_id, owner_boot_id, fn ->
      Repo.transaction(fn -> claim_ownership_locked(session_id, owner_boot_id) end)
    end)
  end

  defp claim_ownership_locked(session_id, owner_boot_id) do
    session = lock_session!(session_id, allow_unowned: true)

    if claimable?(session, owner_boot_id) do
      validate_capacity!(session, owner_boot_id)
      epoch = session.ownership_epoch + 1

      session
      |> Ecto.Changeset.change(owner_boot_id: owner_boot_id, ownership_epoch: epoch)
      |> Repo.update!()

      %Ownership{session_id: session.id, owner_boot_id: owner_boot_id, epoch: epoch}
    else
      Repo.rollback(:session_owned)
    end
  end

  defp claimable?(session, nil),
    do: is_nil(session.owner_boot_id)

  defp claimable?(session, owner_boot_id) do
    unless Instances.ownership_supported_cluster_wide?(
             owner_boot_id,
             @ownership_stale_after_seconds
           ) do
      Repo.rollback(:ownership_capability_not_cluster_wide)
    end

    is_nil(session.owner_boot_id) or session.owner_boot_id == owner_boot_id or
      Instances.same_node?(session.owner_boot_id, owner_boot_id) or
      not Instances.alive?(session.owner_boot_id, @ownership_stale_after_seconds)
  end

  @doc "Transfers a session by advancing its epoch under the current owner's fence."
  def transfer_ownership(%Ownership{} = ownership, new_owner_boot_id) do
    with_placement_locks(ownership.session_id, new_owner_boot_id, fn ->
      Repo.transaction(fn ->
        session = lock_session!(ownership.session_id, ownership: ownership)
        validate_owner_capability!(new_owner_boot_id)
        validate_capacity!(session, new_owner_boot_id)
        epoch = session.ownership_epoch + 1

        session
        |> Ecto.Changeset.change(owner_boot_id: new_owner_boot_id, ownership_epoch: epoch)
        |> Repo.update!()

        %Ownership{
          session_id: session.id,
          owner_boot_id: new_owner_boot_id,
          epoch: epoch
        }
      end)
    end)
  end

  defp validate_owner_capability!(nil), do: :ok

  defp validate_owner_capability!(owner_boot_id) do
    unless Instances.ownership_supported_cluster_wide?(
             owner_boot_id,
             @ownership_stale_after_seconds
           ) do
      Repo.rollback(:ownership_capability_not_cluster_wide)
    end
  end

  defp validate_capacity!(%Session{owner_boot_id: owner_boot_id}, owner_boot_id), do: :ok
  defp validate_capacity!(_session, nil), do: :ok

  defp validate_capacity!(_session, owner_boot_id) do
    instance = Instances.get(owner_boot_id) || Repo.rollback(:instance_not_found)

    load =
      Session
      |> where(
        [session],
        session.owner_boot_id == ^owner_boot_id and session.status in ^@capacity_statuses
      )
      |> Repo.aggregate(:count)

    if load >= instance.capacity, do: Repo.rollback(:instance_at_capacity)
  end

  @doc "Checks a fencing token immediately before dispatching an external effect."
  def assert_owner(%Ownership{} = ownership) do
    query =
      from(session in Session,
        where:
          session.id == ^ownership.session_id and
            session.ownership_epoch == ^ownership.epoch
      )

    query =
      if ownership.owner_boot_id do
        query
        |> join(:inner, [session], instance in Kodo.Cluster.Instance,
          on: instance.boot_id == session.owner_boot_id
        )
        |> where(
          [session, instance],
          session.owner_boot_id == ^ownership.owner_boot_id and
            fragment(
              "? >= timezone('UTC', clock_timestamp()) - (? * interval '1 second')",
              instance.last_seen_at,
              ^@ownership_stale_after_seconds
            )
        )
      else
        where(query, [session], is_nil(session.owner_boot_id))
      end

    if Repo.exists?(query, ControlPlaneTelemetry.repo_options(:ownership_fencing)),
      do: :ok,
      else: {:error, :stale_ownership}
  end

  @doc "Runs an external dispatch while serializing ownership transfer across the cluster."
  def dispatch_if_owner(%Ownership{} = ownership, dispatch) when is_function(dispatch, 0) do
    with_ownership_lock(ownership.session_id, fn ->
      with :ok <- assert_owner(ownership), do: dispatch.()
    end)
  end

  # A separate checkout holds PostgreSQL advisory locks so the caller can perform short database
  # operations without keeping a transaction open across a potentially long external request.
  defp with_ownership_lock(session_id, fun), do: with_locks([session_id], fun)

  defp with_placement_locks(session_id, nil, fun), do: with_ownership_lock(session_id, fun)

  defp with_placement_locks(session_id, owner_boot_id, fun) do
    with_locks([session_id, "instance:#{owner_boot_id}"], fun)
  end

  defp with_locks(lock_keys, fun) do
    caller = self()
    lock_ref = make_ref()

    {holder, holder_ref} =
      spawn_monitor(fn -> hold_locks(caller, lock_ref, Enum.sort(lock_keys)) end)

    receive do
      {^lock_ref, :acquired} ->
        try do
          fun.()
        after
          send(holder, {lock_ref, :release})

          receive do
            {:DOWN, ^holder_ref, :process, ^holder, :normal} -> :ok
            {:DOWN, ^holder_ref, :process, ^holder, reason} -> exit(reason)
          end
        end

      {:DOWN, ^holder_ref, :process, ^holder, reason} ->
        exit(reason)
    end
  end

  defp hold_locks(caller, lock_ref, lock_keys) do
    run_outside_sandbox(fn ->
      Enum.each(lock_keys, fn key ->
        Ecto.Adapters.SQL.query!(Repo, @ownership_lock_sql, [key])
      end)

      caller_ref = Process.monitor(caller)
      send(caller, {lock_ref, :acquired})

      try do
        receive do
          {^lock_ref, :release} -> :ok
          {:DOWN, ^caller_ref, :process, ^caller, _reason} -> :ok
        end
      after
        lock_keys
        |> Enum.reverse()
        |> Enum.each(fn key ->
          Ecto.Adapters.SQL.query!(Repo, @ownership_unlock_sql, [key])
        end)
      end
    end)
  end

  defp run_outside_sandbox(fun) do
    if Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
    else
      Repo.checkout(fun, timeout: :infinity)
    end
  end

  @doc "Returns the unique active coordinator, reconstructing it from events when needed."
  def ensure_started(session_id), do: locate_or_place_active_session(session_id)

  @doc false
  def reconcile_started(session_id) do
    case rehome_legacy_draining_owner(session_id) do
      {:ok, pid} -> {:ok, pid}
      _not_rehomed -> locate_or_place_active_session(session_id)
    end
  end

  defp locate_or_place_active_session(session_id) do
    case Discovery.session(session_id) do
      {:ok, pid} when node(pid) != node() ->
        {:ok, pid}

      {:ok, pid} ->
        if supervised_session?(pid),
          do: {:ok, pid},
          else: await_stale_coordinator(pid, session_id)

      :error ->
        place_active_session(session_id)
    end
  end

  # Older revisions only mark themselves draining. A current node detects that durable intent and
  # performs the fenced transfer so the first rollout of rehoming code is still proactive.
  defp rehome_legacy_draining_owner(session_id) do
    with %Session{owner_boot_id: owner_boot_id} = session when not is_nil(owner_boot_id) <-
           get_session(session_id),
         %{draining: true, protocol_capabilities: capabilities} <- Instances.get(owner_boot_id),
         false <- "session-rehoming-v1" in capabilities do
      session
      |> ownership_for()
      |> rehome_active_session()
    else
      _not_legacy_draining -> :not_rehomed
    end
  end

  defp supervised_session?(pid) do
    Enum.any?(DynamicSupervisor.which_children(Kodo.SessionSupervisor), fn
      {_id, ^pid, _type, _modules} -> true
      _child -> false
    end)
  end

  defp await_stale_coordinator(pid, session_id) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> place_active_session(session_id)
    after
      @stale_coordinator_shutdown_timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :stale_coordinator_did_not_stop}
    end
  end

  def active_state(session_id) do
    case Discovery.session(session_id) do
      {:ok, pid} ->
        active_state_from_coordinator(pid, session_id)

      :error ->
        active_state_from_storage(session_id)
    end
  end

  defp active_state_from_coordinator(pid, session_id) do
    result = call_coordinator(pid, fn -> {:ok, Kodo.Sessions.ActiveSession.state(pid)} end)
    reconcile_unavailable_state(result, session_id)
  end

  defp reconcile_unavailable_state({:error, :coordinator_unavailable} = error, session_id) do
    case active_state_from_storage(session_id) do
      {:error, :not_found} -> error
      result -> result
    end
  end

  defp reconcile_unavailable_state(result, _session_id), do: result

  defp active_state_from_storage(session_id) do
    case get_session(session_id) do
      %Session{status: status} when status in ["running", "awaiting_approval"] ->
        active_coordinator_state(session_id)

      %Session{} ->
        {:ok, session_id |> events_after() |> Projection.from_events()}

      nil ->
        {:error, :not_found}
    end
  end

  defp active_coordinator_state(session_id) do
    with {:ok, pid} <- ensure_started(session_id) do
      call_coordinator(pid, fn -> {:ok, Kodo.Sessions.ActiveSession.state(pid)} end)
    end
  end

  def start_turn(session_id, content), do: start_turn(session_id, content, nil)

  def start_turn(%Scope{} = scope, session_id, content),
    do: start_turn(scope, session_id, content, nil)

  def start_turn(session_id, content, client_request_id) do
    with {:ok, pid} <- ensure_started(session_id) do
      call_coordinator_with_exit_retry(session_id, pid, fn coordinator ->
        Kodo.Sessions.ActiveSession.start_turn(coordinator, content, client_request_id)
      end)
    end
  end

  def begin_turn(session_id, content, client_request_id \\ nil, opts \\ [])
      when is_binary(content) and content != "" do
    case Repo.transaction(fn ->
           begin_turn_locked(session_id, content, client_request_id, opts)
         end) do
      {:ok, events} = result ->
        Enum.each(events, &broadcast/1)
        result

      error ->
        error
    end
  end

  def start_turn(%Scope{} = scope, session_id, content, client_request_id) do
    case get_session(scope, session_id) do
      %Session{} ->
        if turn_request_recorded?(session_id, client_request_id) do
          :ok
        else
          start_turn(session_id, content, client_request_id)
        end

      nil ->
        {:error, :not_found}
    end
  end

  def cancel(session_id) do
    case get_session(session_id) do
      %Session{status: status} when status in ["running", "awaiting_approval"] ->
        cancel_active_session(session_id)

      %Session{} ->
        {:error, :not_running}

      nil ->
        {:error, :not_found}
    end
  end

  defp cancel_active_session(session_id) do
    with {:ok, pid} <- ensure_started(session_id) do
      call_coordinator(pid, fn -> Kodo.Sessions.ActiveSession.cancel(pid) end)
    end
  end

  defp call_coordinator(_pid, call) do
    call.()
  catch
    :exit, reason ->
      if coordinator_unavailable?(reason) do
        {:error, :coordinator_unavailable}
      else
        exit(reason)
      end
  end

  defp call_coordinator_with_exit_retry(session_id, pid, call) do
    case call_coordinator(pid, fn -> call.(pid) end) do
      {:error, :coordinator_unavailable} ->
        retry_coordinator_call(session_id, pid, call)

      result ->
        result
    end
  end

  defp retry_coordinator_call(session_id, pid, call) do
    with {:ok, replacement} <- await_stale_coordinator(pid, session_id) do
      call_coordinator(replacement, fn -> call.(replacement) end)
    end
  end

  defp coordinator_unavailable?({:nodedown, _node}), do: true
  defp coordinator_unavailable?({:noproc, _call}), do: true
  defp coordinator_unavailable?({:normal, {GenServer, :call, _args}}), do: true
  defp coordinator_unavailable?({{:nodedown, _node}, _call}), do: true
  defp coordinator_unavailable?({{:noproc, _detail}, _call}), do: true
  defp coordinator_unavailable?(_reason), do: false

  def cancel(%Scope{} = scope, session_id) do
    case get_session(scope, session_id) do
      %Session{status: "cancelled"} ->
        :ok

      %Session{} ->
        session_id
        |> cancel()
        |> reconcile_cancel(scope, session_id)

      nil ->
        {:error, :not_found}
    end
  end

  defp reconcile_cancel({:error, reason}, scope, session_id)
       when reason in [:not_running, :already_finished, :coordinator_unavailable] do
    if get_session(scope, session_id).status == "cancelled", do: :ok, else: {:error, reason}
  end

  defp reconcile_cancel(result, _scope, _session_id), do: result

  def resolve_approval(%Scope{} = scope, session_id, approval_id, decision)
      when decision in ["approved", "denied"] do
    case get_session(scope, session_id) do
      %Session{} = session ->
        resolve_owned_approval(
          session_id,
          approval_id,
          decision,
          ownership_for(session)
        )

      nil ->
        {:error, :not_found}
    end
  end

  def resolve_approval(%Scope{}, _session_id, _approval_id, _decision),
    do: {:error, :invalid_decision}

  def request_approval(session_id, payload, opts \\ []) do
    case Repo.transaction(fn -> request_approval_locked(session_id, payload, opts) end) do
      {:ok, {requested, status_event}} = result ->
        broadcast(requested)
        broadcast(status_event)
        result

      error ->
        error
    end
  end

  @doc false
  def start_active_session_here(session_id, expected_boot_id) do
    case DynamicSupervisor.start_child(
           Kodo.SessionSupervisor,
           {Kodo.Sessions.ActiveSession, {session_id, expected_boot_id}}
         ) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
  end

  @doc false
  def start_rehomed_active_session_here(session_id, expected_boot_id, previous_ownership) do
    case DynamicSupervisor.start_child(
           Kodo.SessionSupervisor,
           {Kodo.Sessions.ActiveSession, {session_id, expected_boot_id, previous_ownership}}
         ) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
  end

  @doc "Moves an active coordinator to a compatible non-draining instance."
  def rehome_active_session(%Ownership{} = ownership) do
    with {:ok, instance, target_node} <-
           Placement.select_rehome_target(
             ownership.session_id,
             @ownership_stale_after_seconds
           ) do
      start_rehomed_active_session_on(target_node, ownership, instance.boot_id)
    end
  end

  @doc "Requests every locally supervised coordinator owned by a boot to yield for rehoming."
  def drain_owned_sessions(owner_boot_id, timeout) when is_integer(timeout) and timeout > 0 do
    tasks =
      Kodo.SessionSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.map(fn {_id, pid, _type, _modules} ->
        Task.async(fn ->
          try do
            Kodo.Sessions.ActiveSession.begin_drain(pid, owner_boot_id, timeout)
          rescue
            exception -> {:task_error, exception}
          catch
            :exit, reason -> {:task_exit, reason}
          end
        end)
      end)

    tasks
    |> Task.yield_many(timeout)
    |> Enum.map(fn
      {_task, {:ok, result}} ->
        result

      {_task, {:exit, reason}} ->
        {:task_exit, reason}

      {task, nil} ->
        _ = Task.shutdown(task, :brutal_kill)
        :timeout
    end)
    |> Enum.flat_map(fn
      result when result in [:ok, :not_owned] -> []
      {:error, reason} -> [reason]
      error -> [error]
    end)
    |> case do
      [] -> :ok
      errors -> {:error, {:drain_incomplete, errors}}
    end
  end

  defp place_active_session(session_id, attempts \\ @placement_attempts)

  defp place_active_session(_session_id, 0), do: {:error, :placement_conflict}

  defp place_active_session(session_id, attempts) do
    case Process.whereis(InstanceManager) do
      pid when is_pid(pid) ->
        with {:ok, instance, target_node} <-
               Placement.select(session_id, @ownership_stale_after_seconds) do
          target_node
          |> start_active_session_on(session_id, instance.boot_id)
          |> reconcile_placement(session_id, attempts)
        end

      nil ->
        if instance_manager_enabled?(),
          do: {:error, :coordinator_unavailable},
          else: start_active_session_here(session_id, nil)
    end
  end

  defp reconcile_placement({:error, reason}, session_id, attempts)
       when reason in [:instance_at_capacity, :session_owned, :target_boot_mismatch] do
    place_active_session(session_id, attempts - 1)
  end

  defp reconcile_placement(result, _session_id, _attempts), do: result

  defp start_active_session_on(target_node, session_id, expected_boot_id)
       when target_node == node() do
    start_active_session_here(session_id, expected_boot_id)
  end

  defp start_active_session_on(target_node, session_id, expected_boot_id) do
    :erpc.call(target_node, __MODULE__, :start_active_session_here, [session_id, expected_boot_id])
  catch
    _kind, _reason -> {:error, :coordinator_unavailable}
  end

  defp start_rehomed_active_session_on(target_node, ownership, expected_boot_id)
       when target_node == node() do
    start_rehomed_active_session_here(ownership.session_id, expected_boot_id, ownership)
  end

  defp start_rehomed_active_session_on(target_node, ownership, expected_boot_id) do
    :erpc.call(target_node, __MODULE__, :start_rehomed_active_session_here, [
      ownership.session_id,
      expected_boot_id,
      ownership
    ])
  catch
    _kind, _reason -> {:error, :coordinator_unavailable}
  end

  defp instance_manager_enabled? do
    :kodo
    |> Application.fetch_env!(InstanceManager)
    |> Keyword.fetch!(:enabled)
  end

  def create_session(%Scope{} = scope, attrs) do
    do_create_session(scope.user, attrs)
  end

  defp do_create_session(user, attrs) do
    request_id = attrs[:client_request_id] || attrs["client_request_id"]

    case existing_requested_session(user, request_id) ||
           Repo.transaction(fn -> create_session_locked(user, attrs) end) do
      %Session{} = session ->
        {:ok, session}

      {:ok, {session, event}} ->
        broadcast(event)
        {:ok, session}

      {:error, %Ecto.Changeset{}} = error ->
        case existing_requested_session(user, request_id) do
          %Session{} = session -> {:ok, session}
          nil -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing_requested_session(_user, request_id) when not is_binary(request_id), do: nil

  defp existing_requested_session(user, request_id) do
    case Ecto.UUID.cast(request_id) do
      {:ok, request_id} -> Repo.get_by(Session, user_id: user.id, client_request_id: request_id)
      :error -> nil
    end
  end

  def resolve_owned_approval(session_id, approval_id, decision, ownership) do
    case Repo.transaction(fn ->
           resolve_approval_locked(session_id, approval_id, decision, ownership: ownership)
         end) do
      {:ok, {resolved, status_event}} = result ->
        broadcast(resolved)
        broadcast(status_event)
        result

      error ->
        error
    end
  end

  defp ownership_for(%Session{} = session) do
    %Ownership{
      session_id: session.id,
      owner_boot_id: session.owner_boot_id,
      epoch: session.ownership_epoch
    }
  end

  @doc "Appends an event while locking its session row to allocate exactly one sequence number."
  def append_event(session_id, type, payload, opts \\ []) do
    case Repo.transaction(fn -> append_event_locked(session_id, type, payload, opts) end) do
      {:ok, event} = result ->
        broadcast(event)
        result

      error ->
        error
    end
  end

  @doc "Atomically appends an ordered group of events under one session lock."
  def append_events(session_id, event_specs) when is_list(event_specs) and event_specs != [] do
    case Repo.transaction(fn -> append_events_locked(session_id, event_specs) end) do
      {:ok, events} = result ->
        Enum.each(events, &broadcast/1)
        result

      error ->
        error
    end
  end

  def complete_session(session_id, opts \\ []),
    do: finalize_session(session_id, "completed", nil, opts)

  def fail_session(session_id, reason, opts \\ []) do
    finalize_session(
      session_id,
      "failed",
      {"session_failed", %{"reason" => inspect(reason)}},
      opts
    )
  end

  def events_after(session_id), do: events_after(session_id, @before_first_event_sequence)

  def events_after(session_id, sequence)
      when is_integer(sequence) and sequence >= @before_first_event_sequence do
    Event
    |> where([event], event.session_id == ^session_id and event.sequence > ^sequence)
    |> order_by([event], asc: event.sequence)
    |> Repo.all()
  end

  def events_after(%Scope{} = scope, session_id) do
    events_after(scope, session_id, @before_first_event_sequence)
  end

  def events_after(%Scope{user: user}, session_id, sequence)
      when is_integer(sequence) and sequence >= @before_first_event_sequence do
    Event
    |> join(:inner, [event], session in assoc(event, :session))
    |> where(
      [event, session],
      event.session_id == ^session_id and event.sequence > ^sequence and
        session.user_id == ^user.id
    )
    |> order_by([event], asc: event.sequence)
    |> Repo.all()
  end

  def set_status(session_id, status, source \\ "agent", opts \\ []) do
    case Repo.transaction(fn -> set_status_locked(session_id, status, source, opts) end) do
      {:ok, {_session, event}} = result ->
        broadcast(event)
        result

      error ->
        error
    end
  end

  @doc "Atomically records cancellation and updates the session's query index."
  def cancel_session(session_id, opts \\ []) do
    case Repo.transaction(fn -> cancel_session_locked(session_id, opts) end) do
      {:ok, {_session, event}} = result ->
        broadcast(event)
        result

      error ->
        error
    end
  end

  defp append_event_locked(session_id, type, payload, opts) do
    session = lock_session!(session_id, opts)

    case append_locked(session, type, payload, opts) do
      {:ok, event} -> event
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp begin_turn_locked(session_id, content, client_request_id, opts) do
    session = lock_session!(session_id, opts)

    if turn_request_recorded?(session_id, client_request_id) do
      []
    else
      do_begin_turn_locked(session, content, client_request_id)
    end
  end

  defp do_begin_turn_locked(session, content, client_request_id) do
    if session.status in ["running", "awaiting_approval"] do
      Repo.rollback(:turn_in_progress)
    else
      payload =
        %{"role" => "user", "content" => content}
        |> maybe_put_request_id(client_request_id)

      with {:ok, message} <-
             append_locked(
               session,
               "user_message",
               payload,
               []
             ),
           session = %{session | next_event_sequence: session.next_event_sequence + 1},
           {:ok, session} <- session |> Session.status_changeset("running") |> Repo.update(),
           {:ok, status_event} <-
             append_locked(session, "session_status_changed", %{"status" => "running"}, []) do
        [message, status_event]
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end
  end

  defp turn_request_recorded?(_session_id, request_id) when not is_binary(request_id), do: false

  defp turn_request_recorded?(session_id, request_id) do
    Repo.exists?(
      from(event in Event,
        where:
          event.session_id == ^session_id and event.type == "user_message" and
            fragment("?->>'client_request_id'", event.payload) == ^request_id
      )
    )
  end

  defp maybe_put_request_id(payload, request_id) when is_binary(request_id),
    do: Map.put(payload, "client_request_id", request_id)

  defp maybe_put_request_id(payload, _request_id), do: payload

  defp append_events_locked(session_id, event_specs) do
    ownership =
      event_specs
      |> List.first()
      |> elem(2)
      |> Keyword.get(:ownership)

    session = lock_session!(session_id, ownership: ownership)

    {events, _session} =
      Enum.map_reduce(event_specs, session, fn {type, payload, opts}, current_session ->
        case append_locked(current_session, type, payload, opts) do
          {:ok, event} ->
            {event,
             %{current_session | next_event_sequence: current_session.next_event_sequence + 1}}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    events
  end

  defp finalize_session(session_id, status, terminal_event, opts) do
    case Repo.transaction(fn ->
           finalize_session_locked(session_id, status, terminal_event, opts)
         end) do
      {:ok, events} = result ->
        Enum.each(events, &broadcast/1)
        result

      error ->
        error
    end
  end

  defp finalize_session_locked(session_id, status, terminal_event, opts) do
    session = lock_session!(session_id, opts)

    if session.status in ["running", "awaiting_approval"] do
      {events, session} = append_terminal_event(session, terminal_event)

      with {:ok, session} <- session |> Session.status_changeset(status) |> Repo.update(),
           {:ok, status_event} <-
             append_locked(
               session,
               "session_status_changed",
               %{"status" => status},
               source: "agent"
             ) do
        events ++ [status_event]
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    else
      Repo.rollback(:session_not_active)
    end
  end

  defp append_terminal_event(session, nil), do: {[], session}

  defp append_terminal_event(session, {type, payload}) do
    case append_locked(session, type, payload, []) do
      {:ok, event} ->
        {[event], %{session | next_event_sequence: session.next_event_sequence + 1}}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp set_status_locked(session_id, status, source, opts) do
    session = lock_session!(session_id, opts)

    with {:ok, session} <- session |> Session.status_changeset(status) |> Repo.update(),
         {:ok, event} <-
           append_locked(session, "session_status_changed", %{"status" => status}, source: source) do
      {session, event}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp cancel_session_locked(session_id, opts) do
    session = lock_session!(session_id, opts)

    with {:ok, session} <-
           session |> Session.status_changeset("cancelled") |> Repo.update(),
         {:ok, event} <-
           append_locked(
             session,
             "session_cancelled",
             %{"reason" => "user_requested"},
             source: "user"
           ) do
      {session, event}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp resolve_approval_locked(session_id, approval_id, decision, opts) do
    session = lock_session!(session_id, opts)
    existing_decision = approval_decision(session_id, approval_id)

    pending? =
      session.status == "awaiting_approval" and
        current_approval_id(session_id) == approval_id and
        is_nil(existing_decision)

    cond do
      existing_decision == decision ->
        :already_resolved

      not is_nil(existing_decision) ->
        Repo.rollback(:approval_already_resolved)

      pending? ->
        with {:ok, resolved} <-
               append_locked(
                 session,
                 "approval_resolved",
                 %{"approval_id" => approval_id, "decision" => decision},
                 source: "user"
               ),
             refreshed = lock_session!(session_id, opts),
             {:ok, refreshed} <-
               refreshed |> Session.status_changeset("running") |> Repo.update(),
             {:ok, status_event} <-
               append_locked(
                 refreshed,
                 "session_status_changed",
                 %{"status" => "running"},
                 source: "user"
               ) do
          {resolved, status_event}
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end

      true ->
        Repo.rollback(:approval_not_pending)
    end
  end

  defp request_approval_locked(session_id, payload, opts) do
    session = lock_session!(session_id, opts)

    if session.status == "running" do
      with {:ok, requested} <-
             append_locked(session, "approval_requested", payload,
               parent_id: Keyword.get(opts, :parent_id)
             ),
           refreshed = lock_session!(session_id, opts),
           {:ok, refreshed} <-
             refreshed |> Session.status_changeset("awaiting_approval") |> Repo.update(),
           {:ok, status_event} <-
             append_locked(
               refreshed,
               "session_status_changed",
               %{
                 "status" => "awaiting_approval"
               },
               []
             ) do
        {requested, status_event}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    else
      Repo.rollback(:session_not_running)
    end
  end

  defp current_approval_id(session_id) do
    Repo.one(
      from(event in Event,
        where: event.session_id == ^session_id and event.type == "approval_requested",
        order_by: [desc: event.sequence],
        select: fragment("?->>'approval_id'", event.payload),
        limit: 1
      )
    )
  end

  defp approval_decision(session_id, approval_id) do
    Repo.one(
      from(event in Event,
        where:
          event.session_id == ^session_id and event.type == "approval_resolved" and
            fragment("?->>'approval_id'", event.payload) == ^approval_id,
        select: fragment("?->>'decision'", event.payload),
        limit: 1
      )
    )
  end

  defp create_session_locked(user, attrs) do
    runner = authorize_runner!(user, attrs[:runner_id] || attrs["runner_id"])
    session = if user, do: %Session{user_id: user.id}, else: %Session{}

    {model_mapping, attrs} =
      resolve_session_model(attrs, ModelSettings.layers(user.id, runner.id))

    with {:ok, session} <- session |> Session.create_changeset(attrs) |> Repo.insert(),
         {:ok, event} <-
           append_locked(
             session,
             "session_created",
             %{
               "title" => session.title,
               "runner_id" => session.runner_id,
               "model" => session.model,
               "model_mapping" => model_mapping,
               "approval_policy" => session.approval_policy,
               "status" => session.status
             },
             source: "system"
           ) do
      {Repo.get!(Session, session.id), event}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp resolve_session_model(attrs, override_layers) do
    case fetch_attr(attrs, :model) do
      :error ->
        mapping = Kodo.Agent.ModelMapping.balanced(override_layers)
        primary = Kodo.Agent.ModelMapping.role!(mapping, :primary)
        {mapping, put_session_model(attrs, primary["model"])}

      {:ok, model} when is_binary(model) and model != "" ->
        layers = override_layers ++ [{"session", %{primary: %{model: model}}}]
        {Kodo.Agent.ModelMapping.balanced(layers), attrs}

      {:ok, _invalid} ->
        {Kodo.Agent.ModelMapping.balanced(override_layers), attrs}
    end
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      :error -> Map.fetch(attrs, Atom.to_string(key))
      result -> result
    end
  end

  defp put_session_model(attrs, model) do
    if Enum.any?(Map.keys(attrs), &is_binary/1) do
      Map.put(attrs, "model", model)
    else
      Map.put(attrs, :model, model)
    end
  end

  defp authorize_runner!(user, runner_id) do
    runner =
      case Ecto.UUID.cast(runner_id) do
        {:ok, runner_id} ->
          Runner
          |> where([runner], runner.id == ^runner_id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        :error ->
          nil
      end

    cond do
      is_nil(runner) ->
        Repo.rollback(:runner_not_found)

      runner.user_id == user.id ->
        runner

      true ->
        Repo.rollback(:runner_not_authorized)
    end
  end

  defp lock_session!(session_id, opts) do
    session =
      Session
      |> where([session], session.id == ^session_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

    ownership = Keyword.get(opts, :ownership)

    cond do
      Keyword.get(opts, :allow_unowned, false) -> session
      ownership_matches?(session, ownership) and owner_alive?(ownership) -> session
      true -> Repo.rollback(:stale_ownership)
    end
  end

  defp owner_alive?(nil), do: true
  defp owner_alive?(%Ownership{owner_boot_id: nil}), do: true

  defp owner_alive?(%Ownership{owner_boot_id: owner_boot_id}) do
    Instances.alive?(
      owner_boot_id,
      @ownership_stale_after_seconds,
      ControlPlaneTelemetry.repo_options(:ownership_fencing)
    )
  end

  defp ownership_matches?(%Session{ownership_epoch: 0}, nil), do: true

  defp ownership_matches?(%Session{} = session, %Ownership{} = ownership) do
    session.id == ownership.session_id and
      session.owner_boot_id == ownership.owner_boot_id and
      session.ownership_epoch == ownership.epoch
  end

  defp ownership_matches?(_session, _ownership), do: false

  defp append_locked(session, type, payload, opts) do
    attrs = %{
      session_id: session.id,
      sequence: session.next_event_sequence,
      type: type,
      version: Keyword.get(opts, :version, @initial_event_version),
      payload: payload,
      source: Keyword.get(opts, :source, "agent"),
      parent_id: Keyword.get(opts, :parent_id)
    }

    with {:ok, event} <- %Event{} |> Event.changeset(attrs) |> Repo.insert(),
         {@single_updated_row, nil} <-
           Session
           |> where([record], record.id == ^session.id)
           |> Repo.update_all(
             inc: [next_event_sequence: @single_event_increment],
             set: [updated_at: DateTime.utc_now()]
           ) do
      {:ok, event}
    end
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(
      Kodo.PubSub,
      "session:#{event.session_id}",
      {:session_event, event}
    )

    if event.type in @session_index_event_types do
      user_id =
        Repo.one(
          from session in Session, where: session.id == ^event.session_id, select: session.user_id
        )

      Phoenix.PubSub.broadcast(
        Kodo.PubSub,
        session_index_topic(user_id),
        {:session_index_changed, event.session_id}
      )
    end
  end

  defp before_cursor(query, nil), do: query

  defp before_cursor(query, %{updated_at: updated_at, id: id}) do
    where(
      query,
      [session],
      session.updated_at < ^updated_at or
        (session.updated_at == ^updated_at and session.id < ^id)
    )
  end

  defp session_cursor(nil), do: nil
  defp session_cursor(session), do: %{updated_at: session.updated_at, id: session.id}
  defp session_index_topic(user_id), do: @session_index_topic_prefix <> Integer.to_string(user_id)

  defp before_event_sequence(query, nil), do: query

  defp before_event_sequence(query, sequence) when is_integer(sequence) do
    where(query, [event], event.sequence < ^sequence)
  end

  defp visible_tool_calls(_user_id, _session_id, []), do: %{}

  defp visible_tool_calls(user_id, session_id, tool_call_ids) do
    Event
    |> join(:inner, [event], session in assoc(event, :session))
    |> where(
      [event, session],
      event.session_id == ^session_id and session.user_id == ^user_id and
        event.type in @timeline_tool_types and
        fragment("?->>'tool_call_id'", event.payload) in ^tool_call_ids
    )
    |> order_by([event], asc: event.sequence)
    |> Repo.all()
    |> Projection.from_events()
    |> Map.fetch!(:tool_calls)
  end
end
