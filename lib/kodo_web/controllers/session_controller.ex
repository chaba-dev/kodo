defmodule KodoWeb.SessionController do
  @moduledoc "JSON control and replay API for durable primary-agent sessions."

  use KodoWeb, :controller

  alias Kodo.Sessions

  @before_first_event_sequence 0

  def create(conn, params) do
    case Sessions.create_session(params) do
      {:ok, session} ->
        conn |> put_status(:created) |> json(%{session: session_json(session)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors(changeset)})
    end
  end

  def show(conn, %{"id" => id} = params) do
    case Sessions.get_session(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "session not found"})

      _session ->
        with {:ok, cursor} <- cursor(params["after_sequence"]) do
          all_events = Sessions.events_after(id)
          projection = Kodo.Sessions.Projection.from_events(all_events)

          json(conn, %{
            session: projection_json(projection),
            events:
              all_events
              |> Enum.drop_while(&(&1.sequence <= cursor))
              |> Enum.map(&event_json/1)
          })
        else
          :error -> conn |> put_status(:bad_request) |> json(%{error: "invalid event cursor"})
        end
    end
  end

  def message(conn, %{"id" => id, "content" => content}) when is_binary(content) do
    content = String.trim(content)

    if content == "" do
      conn |> put_status(:unprocessable_entity) |> json(%{error: "content is required"})
    else
      start_turn(conn, id, content)
    end
  end

  def message(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "content is required"})

  defp start_turn(conn, id, content) do
    if Sessions.get_session(id) do
      case Sessions.start_turn(id, content) do
        :ok -> conn |> put_status(:accepted) |> json(%{status: "running"})
        {:error, reason} -> conn |> put_status(:conflict) |> json(%{error: inspect(reason)})
      end
    else
      conn |> put_status(:not_found) |> json(%{error: "session not found"})
    end
  end

  def cancel(conn, %{"id" => id}) do
    if Sessions.get_session(id) do
      case Sessions.cancel(id) do
        :ok -> json(conn, %{status: "cancelled"})
        {:error, reason} -> conn |> put_status(:conflict) |> json(%{error: inspect(reason)})
      end
    else
      conn |> put_status(:not_found) |> json(%{error: "session not found"})
    end
  end

  defp session_json(session) do
    %{
      id: session.id,
      runner_id: session.runner_id,
      title: session.title,
      model: session.model,
      status: session.status
    }
  end

  defp projection_json(projection) do
    %{
      id: projection.id,
      runner_id: projection.runner_id,
      title: projection.title,
      model: projection.model,
      status: projection.status
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
