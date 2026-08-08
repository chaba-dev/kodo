defmodule Kodo.Sessions do
  @moduledoc "Creates sessions and owns their immutable, monotonically ordered event logs."

  import Ecto.Query

  alias Kodo.Repo
  alias Kodo.Sessions.Event
  alias Kodo.Sessions.Session

  def get_session(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.get(Session, id)
    else
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

  def cancel(session_id) do
    with {:ok, pid} <- ensure_started(session_id) do
      Kodo.Sessions.ActiveSession.cancel(pid)
    end
  end

  defp start_active_session(session_id) do
    DynamicSupervisor.start_child(
      Kodo.SessionSupervisor,
      {Kodo.Sessions.ActiveSession, session_id}
    )
  end

  def create_session(attrs) do
    case Repo.transaction(fn -> create_session_locked(attrs) end) do
      {:ok, {session, event}} ->
        broadcast(event)
        {:ok, session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Appends an event while locking its session row to allocate exactly one sequence number."
  def append_event(session_id, type, payload, opts \\ []) do
    case Repo.transaction(fn ->
           session = lock_session!(session_id)

           case append_locked(session, type, payload, opts) do
             {:ok, event} -> event
             {:error, changeset} -> Repo.rollback(changeset)
           end
         end) do
      {:ok, event} = result ->
        broadcast(event)
        result

      error ->
        error
    end
  end

  def events_after(session_id, sequence \\ 0) when is_integer(sequence) and sequence >= 0 do
    Event
    |> where([event], event.session_id == ^session_id and event.sequence > ^sequence)
    |> order_by([event], asc: event.sequence)
    |> Repo.all()
  end

  def set_status(session_id, status, source \\ "agent") do
    case Repo.transaction(fn ->
           session = lock_session!(session_id)

           with {:ok, session} <- session |> Session.status_changeset(status) |> Repo.update(),
                {:ok, event} <-
                  append_locked(session, "session_status_changed", %{"status" => status},
                    source: source
                  ) do
             {session, event}
           else
             {:error, changeset} -> Repo.rollback(changeset)
           end
         end) do
      {:ok, {_session, event}} = result ->
        broadcast(event)
        result

      error ->
        error
    end
  end

  @doc "Atomically records cancellation and updates the session's query index."
  def cancel_session(session_id) do
    case Repo.transaction(fn ->
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
         end) do
      {:ok, {_session, event}} = result ->
        broadcast(event)
        result

      error ->
        error
    end
  end

  defp create_session_locked(attrs) do
    with {:ok, session} <- %Session{} |> Session.create_changeset(attrs) |> Repo.insert(),
         {:ok, event} <-
           append_locked(
             session,
             "session_created",
             %{
               "title" => session.title,
               "runner_id" => session.runner_id,
               "model" => session.model,
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
      version: Keyword.get(opts, :version, 1),
      payload: payload,
      source: Keyword.get(opts, :source, "agent"),
      parent_id: Keyword.get(opts, :parent_id)
    }

    with {:ok, event} <- %Event{} |> Event.changeset(attrs) |> Repo.insert(),
         {1, nil} <-
           Session
           |> where([record], record.id == ^session.id)
           |> Repo.update_all(inc: [next_event_sequence: 1]) do
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
