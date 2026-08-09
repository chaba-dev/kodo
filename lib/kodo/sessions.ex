defmodule Kodo.Sessions do
  @moduledoc "Creates sessions and owns their immutable, monotonically ordered event logs."

  import Ecto.Query

  alias Kodo.Accounts.Scope
  alias Kodo.Repo
  alias Kodo.Sessions.Event
  alias Kodo.Sessions.Session

  @before_first_event_sequence 0
  @initial_event_version 1
  @single_event_increment 1
  @single_updated_row 1

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

  @doc "Returns the unique active coordinator, reconstructing it from events when needed."
  def ensure_started(session_id) do
    case Registry.lookup(Kodo.SessionRegistry, session_id) do
      [{pid, _value}] ->
        if Process.info(pid) do
          {:ok, pid}
        else
          start_active_session(session_id)
        end

      [] ->
        start_active_session(session_id)
    end
  end

  def active_state(session_id) do
    with {:ok, pid} <- ensure_started(session_id) do
      {:ok, Kodo.Sessions.ActiveSession.state(pid)}
    end
  end

  def start_turn(session_id, content) do
    with {:ok, pid} <- ensure_started(session_id) do
      Kodo.Sessions.ActiveSession.start_turn(pid, content)
    end
  end

  def start_turn(%Scope{} = scope, session_id, content) do
    case get_session(scope, session_id) do
      %Session{} -> start_turn(session_id, content)
      nil -> {:error, :not_found}
    end
  end

  def cancel(session_id) do
    with {:ok, pid} <- ensure_started(session_id) do
      Kodo.Sessions.ActiveSession.cancel(pid)
    end
  end

  def cancel(%Scope{} = scope, session_id) do
    case get_session(scope, session_id) do
      %Session{} -> cancel(session_id)
      nil -> {:error, :not_found}
    end
  end

  def resolve_approval(%Scope{} = scope, session_id, approval_id, decision)
      when decision in ["approved", "denied"] do
    case get_session(scope, session_id) do
      %Session{} -> do_resolve_approval(session_id, approval_id, decision)
      nil -> {:error, :not_found}
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
    DynamicSupervisor.start_child(
      Kodo.SessionSupervisor,
      {Kodo.Sessions.ActiveSession, session_id}
    )
  end

  def create_session(%Scope{} = scope, attrs) do
    do_create_session(scope.user, attrs)
  end

  defp do_create_session(user, attrs) do
    case Repo.transaction(fn -> create_session_locked(user, attrs) end) do
      {:ok, {session, event}} ->
        broadcast(event)
        {:ok, session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_resolve_approval(session_id, approval_id, decision) do
    case Repo.transaction(fn -> resolve_approval_locked(session_id, approval_id, decision) end) do
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

  def set_status(session_id, status, source \\ "agent") do
    case Repo.transaction(fn -> set_status_locked(session_id, status, source) end) do
      {:ok, {_session, event}} = result ->
        broadcast(event)
        result

      error ->
        error
    end
  end

  @doc "Atomically records cancellation and updates the session's query index."
  def cancel_session(session_id) do
    case Repo.transaction(fn -> cancel_session_locked(session_id) end) do
      {:ok, {_session, event}} = result ->
        broadcast(event)
        result

      error ->
        error
    end
  end

  defp append_event_locked(session_id, type, payload, opts) do
    session = lock_session!(session_id)

    case append_locked(session, type, payload, opts) do
      {:ok, event} -> event
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp set_status_locked(session_id, status, source) do
    session = lock_session!(session_id)

    with {:ok, session} <- session |> Session.status_changeset(status) |> Repo.update(),
         {:ok, event} <-
           append_locked(session, "session_status_changed", %{"status" => status}, source: source) do
      {session, event}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp cancel_session_locked(session_id) do
    session = lock_session!(session_id)

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

  defp resolve_approval_locked(session_id, approval_id, decision) do
    session = lock_session!(session_id)
    existing_decision = approval_decision(session_id, approval_id)

    pending? =
      session.status == "awaiting_approval" and
        approval_requested?(session_id, approval_id) and
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
             refreshed = lock_session!(session_id),
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
    session = lock_session!(session_id)

    if session.status == "running" do
      with {:ok, requested} <-
             append_locked(session, "approval_requested", payload,
               parent_id: Keyword.get(opts, :parent_id)
             ),
           refreshed = lock_session!(session_id),
           {:ok, refreshed} <-
             refreshed |> Session.status_changeset("awaiting_approval") |> Repo.update(),
           {:ok, status_event} <-
             append_locked(refreshed, "session_status_changed", %{
               "status" => "awaiting_approval"
             }) do
        {requested, status_event}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    else
      Repo.rollback(:session_not_running)
    end
  end

  defp approval_requested?(session_id, approval_id) do
    Repo.exists?(
      from(event in Event,
        where:
          event.session_id == ^session_id and event.type == "approval_requested" and
            fragment("?->>'approval_id'", event.payload) == ^approval_id
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

  defp lock_session!(session_id) do
    Session
    |> where([session], session.id == ^session_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

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
