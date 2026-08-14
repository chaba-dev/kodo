defmodule KodoWeb.SessionController do
  @moduledoc "JSON control and replay API for durable primary-agent sessions."

  use KodoWeb, :controller

  alias Kodo.Sessions

  @before_first_event_sequence 0
  @event_page_size 4

  def create(conn, params) do
    case Sessions.create_session(conn.assigns.current_scope, params) do
      {:ok, session} ->
        conn |> put_status(:created) |> json(%{session: session_json(session)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors(changeset)})

      {:error, reason} when reason in [:runner_not_found, :runner_not_authorized] ->
        conn |> put_status(:forbidden) |> json(%{error: "runner is not available"})
    end
  end

  def show(conn, %{"id" => id} = params) do
    case Sessions.get_session(conn.assigns.current_scope, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "session not found"})

      _session ->
        case cursor(params["after_sequence"]) do
          {:ok, cursor} -> show_session(conn, id, cursor)
          :error -> conn |> put_status(:bad_request) |> json(%{error: "invalid event cursor"})
        end
    end
  end

  defp show_session(conn, id, cursor) do
    all_events = Sessions.events_after(conn.assigns.current_scope, id)
    projection = Kodo.Sessions.Projection.from_events(all_events)

    page =
      all_events |> Enum.drop_while(&(&1.sequence <= cursor)) |> Enum.take(@event_page_size + 1)

    has_more = length(page) > @event_page_size

    json(conn, %{
      session: projection_json(projection),
      events: page |> Enum.take(@event_page_size) |> Enum.map(&event_json/1),
      has_more: has_more
    })
  end

  def message(conn, %{"id" => id, "content" => content} = params) when is_binary(content) do
    content = String.trim(content)
    client_request_id = params["client_request_id"]

    cond do
      content == "" ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "content is required"})

      is_binary(client_request_id) and match?(:error, Ecto.UUID.cast(client_request_id)) ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid client request id"})

      true ->
        start_turn(conn, id, content, client_request_id)
    end
  end

  def message(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "content is required"})

  defp start_turn(conn, id, content, client_request_id) do
    case Sessions.start_turn(conn.assigns.current_scope, id, content, client_request_id) do
      :ok ->
        conn |> put_status(:accepted) |> json(%{status: "running"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "session not found"})

      {:error, reason} ->
        conn |> put_status(:conflict) |> json(%{error: inspect(reason)})
    end
  end

  def cancel(conn, %{"id" => id}) do
    case Sessions.cancel(conn.assigns.current_scope, id) do
      :ok ->
        json(conn, %{status: "cancelled"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "session not found"})

      {:error, reason} ->
        conn |> put_status(:conflict) |> json(%{error: inspect(reason)})
    end
  end

  def resolve_approval(conn, %{"id" => id, "approval_id" => approval_id, "decision" => decision}) do
    case Sessions.resolve_approval(conn.assigns.current_scope, id, approval_id, decision) do
      {:ok, {_resolved, _status_event}} ->
        json(conn, %{status: "running", decision: decision})

      {:ok, :already_resolved} ->
        json(conn, %{status: "running", decision: decision})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "session not found"})

      {:error, :invalid_decision} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid decision"})

      {:error, :approval_not_pending} ->
        conn |> put_status(:conflict) |> json(%{error: "approval is not pending"})

      {:error, :approval_already_resolved} ->
        conn |> put_status(:conflict) |> json(%{error: "approval was resolved differently"})

      {:error, reason} ->
        conn |> put_status(:conflict) |> json(%{error: inspect(reason)})
    end
  end

  def resolve_approval(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "decision is required"})

  defp session_json(session) do
    %{
      id: session.id,
      runner_id: session.runner_id,
      title: session.title,
      model: session.model,
      approval_policy: session.approval_policy,
      status: session.status
    }
  end

  defp projection_json(projection) do
    %{
      id: projection.id,
      runner_id: projection.runner_id,
      title: projection.title,
      model: projection.model,
      approval_policy: projection.approval_policy,
      status: projection.status,
      pending_approval_id: projection.pending_approval_id
    }
  end

  defp event_json(event) do
    %{
      id: event.id,
      sequence: event.sequence,
      type: event.type,
      version: event.version,
      payload: event.payload,
      source: event.source,
      parent_id: event.parent_id,
      inserted_at: event.inserted_at
    }
  end

  defp cursor(nil), do: {:ok, @before_first_event_sequence}

  defp cursor(value) when is_binary(value) do
    case Integer.parse(value) do
      {cursor, ""} when cursor >= @before_first_event_sequence -> {:ok, cursor}
      _ -> :error
    end
  end

  defp cursor(_value), do: :error

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, text ->
        String.replace(text, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
