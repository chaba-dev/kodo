defmodule Kodo.Sessions do
  @moduledoc "Creates sessions and owns their immutable, monotonically ordered event logs."

  import Ecto.Query

  alias Kodo.Accounts.Scope
  alias Kodo.Repo
  alias Kodo.Sessions.Event
  alias Kodo.Sessions.Ownership
  alias Kodo.Sessions.Session
  alias Kodo.Runners.Runner

  @before_first_event_sequence 0
  @initial_event_version 1
  @single_event_increment 1
  @single_updated_row 1
  @stale_coordinator_shutdown_timeout 5_000

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

  def list_active_sessions do
    Session
    |> where([session], session.status in ["running", "awaiting_approval"])
    |> Repo.all()
  end

  @doc "Claims an unowned session, or replaces a prior coordinator from the same boot."
  def claim_ownership(session_id, owner_boot_id) do
    Repo.transaction(fn ->
      session = lock_session!(session_id, allow_unowned: true)

      if is_nil(session.owner_boot_id) or session.owner_boot_id == owner_boot_id do
        epoch = session.ownership_epoch + 1

        session
        |> Ecto.Changeset.change(owner_boot_id: owner_boot_id, ownership_epoch: epoch)
        |> Repo.update!()

        %Ownership{session_id: session.id, owner_boot_id: owner_boot_id, epoch: epoch}
      else
        Repo.rollback(:session_owned)
      end
    end)
  end

  @doc "Transfers a session by advancing its epoch under the current owner's fence."
  def transfer_ownership(%Ownership{} = ownership, new_owner_boot_id) do
    Repo.transaction(fn ->
      session = lock_session!(ownership.session_id, ownership: ownership)
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
        where(query, [session], session.owner_boot_id == ^ownership.owner_boot_id)
      else
        where(query, [session], is_nil(session.owner_boot_id))
      end

    if Repo.exists?(query), do: :ok, else: {:error, :stale_ownership}
  end

  @doc "Returns the unique active coordinator, reconstructing it from events when needed."
  def ensure_started(session_id) do
    case Registry.lookup(Kodo.SessionRegistry, session_id) do
      [{pid, _value}] ->
        if supervised_session?(pid) do
          {:ok, pid}
        else
          await_stale_coordinator(pid, session_id)
        end

      [] ->
        start_active_session(session_id)
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
      {:DOWN, ^ref, :process, ^pid, _reason} -> start_active_session(session_id)
    after
      @stale_coordinator_shutdown_timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :stale_coordinator_did_not_stop}
    end
  end

  def active_state(session_id) do
    with {:ok, pid} <- ensure_started(session_id) do
      {:ok, Kodo.Sessions.ActiveSession.state(pid)}
    end
  end

  def start_turn(session_id, content), do: start_turn(session_id, content, nil)

  def start_turn(%Scope{} = scope, session_id, content),
    do: start_turn(scope, session_id, content, nil)

  def start_turn(session_id, content, client_request_id) do
    with {:ok, pid} <- ensure_started(session_id) do
      Kodo.Sessions.ActiveSession.start_turn(pid, content, client_request_id)
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
    with {:ok, pid} <- ensure_started(session_id) do
      Kodo.Sessions.ActiveSession.cancel(pid)
    end
  end

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
       when reason in [:not_running, :already_finished] do
    if get_session(scope, session_id).status == "cancelled", do: :ok, else: {:error, reason}
  end

  defp reconcile_cancel(result, _scope, _session_id), do: result

  def resolve_approval(%Scope{} = scope, session_id, approval_id, decision)
      when decision in ["approved", "denied"] do
    case get_session(scope, session_id) do
      %Session{} ->
        with {:ok, pid} <- ensure_started(session_id) do
          Kodo.Sessions.ActiveSession.resolve_approval(pid, approval_id, decision)
        end

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

  defp start_active_session(session_id) do
    case DynamicSupervisor.start_child(
           Kodo.SessionSupervisor,
           {Kodo.Sessions.ActiveSession, session_id}
         ) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
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
    _runner = authorize_runner!(user, attrs[:runner_id] || attrs["runner_id"])
    session = if user, do: %Session{user_id: user.id}, else: %Session{}

    with {:ok, session} <- session |> Session.create_changeset(attrs) |> Repo.insert(),
         {:ok, event} <-
           append_locked(
             session,
             "session_created",
             %{
               "title" => session.title,
               "runner_id" => session.runner_id,
               "model" => session.model,
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
      ownership_matches?(session, ownership) -> session
      true -> Repo.rollback(:stale_ownership)
    end
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
           |> Repo.update_all(inc: [next_event_sequence: @single_event_increment]) do
      {:ok, event}
    end
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(
      Kodo.PubSub,
      "session:#{event.session_id}",
      {:session_event, event}
    )
  end
end
