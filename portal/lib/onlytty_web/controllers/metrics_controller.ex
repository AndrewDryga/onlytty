defmodule OnlyttyWeb.MetricsController do
  @moduledoc """
  `GET /metrics` — Prometheus text exposition of the low-cardinality operator
  counters in `Onlytty.Metrics`. Aggregate-only: it reveals nothing about any
  individual session. Access is gated by `OnlyttyWeb.MetricsAccess` (loopback by
  default, or a bearer token), so it is not reachable by the public internet.
  """

  use OnlyttyWeb, :controller

  plug OnlyttyWeb.MetricsAccess

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, Onlytty.Metrics.render())
  end
end
