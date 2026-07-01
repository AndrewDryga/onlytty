defmodule OnlyTTYWeb.MetricsAccess do
  @moduledoc """
  Access gate for `GET /metrics`. The counters are aggregate-only (no per-session
  data), but the endpoint still isn't for the public internet, so we enforce it
  rather than just asking operators to firewall it.

  Allowed: a loopback client (an on-box scrape), or — when `ONLYTTY_METRICS_TOKEN`
  is set — any client presenting `Authorization: Bearer <token>` (e.g. Prometheus
  reaching it through the load balancer). Everything else gets 404, which also
  doesn't confirm the endpoint exists.

  The check is against `conn.remote_ip`, the real TCP peer. We deliberately do NOT
  trust `X-Forwarded-For` here: a spoofed `127.0.0.1` must not pass the loopback
  gate. Behind the Google HTTPS LB the peer is the LB (never loopback), so public
  traffic must carry the token; an on-box scrape connects over loopback and passes.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if loopback?(conn.remote_ip) or token_ok?(conn) do
      conn
    else
      conn |> send_resp(404, "not found") |> halt()
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv4-mapped loopback (::ffff:127.0.0.0/8) — a 127/8 client on the dual-stack socket.
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, g, _}) when g in 0x7F00..0x7FFF, do: true
  defp loopback?(_), do: false

  defp token_ok?(conn) do
    case Application.get_env(:onlytty, :metrics_token) do
      token when is_binary(token) and token != "" ->
        case get_req_header(conn, "authorization") do
          ["Bearer " <> presented] -> Plug.Crypto.secure_compare(presented, token)
          _ -> false
        end

      _ ->
        false
    end
  end
end
