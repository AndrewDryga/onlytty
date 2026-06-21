defmodule OnlyttyWeb.MetricsController do
  @moduledoc """
  `GET /metrics` — Prometheus text exposition of the low-cardinality operator
  counters in `Onlytty.Metrics`. Aggregate-only: it reveals nothing about any
  individual session. It must still be firewalled or kept behind the proxy, not
  exposed publicly (see README's deploy/ops section).
  """

  use OnlyttyWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, Onlytty.Metrics.render())
  end
end
