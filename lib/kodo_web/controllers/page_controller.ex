defmodule KodoWeb.PageController do
  use KodoWeb, :controller

  alias Kodo.Sessions

  def home(conn, _params) do
    render(conn, :home)
  end

  def session_handoff(conn, %{"id" => id}) do
    case Sessions.get_session(conn.assigns.current_scope, id) do
      nil -> send_resp(conn, :not_found, "Session not found")
      session -> render(conn, :session_handoff, session: session)
    end
  end
end
