defmodule OnlyTTYWeb.MetricsController do
  @moduledoc """
  `GET /metrics` — Prometheus text exposition of the low-cardinality operator
  counters in `OnlyTTY.Metrics`. Aggregate-only: it reveals nothing about any
  individual session. Access is gated by `OnlyTTYWeb.MetricsAccess` (loopback by
  default, or a bearer token), so it is not reachable by the public internet.
  """

  use OnlyTTYWeb, :controller

  plug OnlyTTYWeb.MetricsAccess

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, OnlyTTY.Metrics.render())
  end
end
