defmodule LongOrShortWeb.HealthController do
  use LongOrShortWeb, :controller

  # Lightweight liveness probe for Fly.io healthcheck (LON-127).
  # Intentionally does NOT touch the database, run policies, or
  # fetch a session — Fly cycles the Machine on repeated failures,
  # so the probe must stay green during migrations, transient DB
  # slowness, or auth backend hiccups. If we want a deeper readiness
  # check later (DB ping, Oban queue stats), it should live on a
  # separate path like `/ready`, not here.
  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end
end
