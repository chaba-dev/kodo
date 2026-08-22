defmodule KodoWeb.PageControllerTest do
  use KodoWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/sessions"
  end
end
