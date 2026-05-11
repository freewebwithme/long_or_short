defmodule LongOrShortWeb.HealthControllerTest do
  use LongOrShortWeb.ConnCase, async: true

  # Fly.io healthcheck contract (LON-127):
  # - 200 OK on every request, even without authentication
  # - Plain-text body "ok"
  # - No browser pipeline side effects (session, CSRF, layout)
  test "GET /health returns plain-text ok for anonymous callers", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert response(conn, 200) == "ok"
    assert conn |> get_resp_header("content-type") |> List.first() =~ "text/plain"
  end
end
