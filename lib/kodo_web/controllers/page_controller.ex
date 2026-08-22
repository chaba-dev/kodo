defmodule KodoWeb.PageController do
  use KodoWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/sessions")
  end
end
