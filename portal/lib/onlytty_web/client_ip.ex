defmodule OnlyTTYWeb.ClientIP do
  @moduledoc """
  Resolves the client IP to key `POST /api/sessions` rate limiting on, in a way that
  is proxy-aware WITHOUT trusting a spoofable `X-Forwarded-For` from arbitrary clients.

  The knob is `ONLYTTY_TRUSTED_PROXY_HOPS` (app env `:trusted_proxy_hops`, default 0):
  the number of trusted reverse proxies between the client and this relay.

    * `0` (default) — no proxy. Key on `conn.remote_ip` (the direct TCP peer) and ignore
      `X-Forwarded-For` entirely. This is the self-host / bare deployment behavior.
    * `N > 0` — the last `N` `X-Forwarded-For` entries were appended by your own infra, so
      the real client is the entry `N` positions from the RIGHT. Behind the Google HTTPS
      LB set it to `1`: the LB appends `<client>, <GFE>`, so the client is the
      second-to-last entry.

  Why this is spoof-resistant: we read a FIXED offset from the right (infra-controlled)
  end of the list, not a fixed position from the left. A client can prepend arbitrary
  `X-Forwarded-For` entries, but your proxy always appends the real values after them, so
  the spoofed entries only push the real client further left — they never land on the
  offset we read. A short or malformed header falls back to the direct peer.

  This is deliberately scoped to the rate-limit key. It never rewrites `conn.remote_ip`,
  because `OnlyTTYWeb.MetricsAccess` relies on that being the real TCP peer for its
  loopback gate — resolving a spoofed `X-Forwarded-For` into it would let an attacker
  claim `127.0.0.1` and read `/metrics`.
  """

  @doc "The client IP to throttle on, per the configured trusted-proxy hop count."
  @spec resolve(Plug.Conn.t()) :: :inet.ip_address()
  def resolve(%Plug.Conn{} = conn) do
    hops = Application.get_env(:onlytty, :trusted_proxy_hops, 0)

    if is_integer(hops) and hops > 0 do
      from_forwarded_for(conn, hops) || conn.remote_ip
    else
      conn.remote_ip
    end
  end

  # The client is the entry `hops` positions before the end of X-Forwarded-For (the last
  # `hops` entries are our own trusted proxies). Returns nil — so resolve/1 falls back to
  # the direct peer — when the header is too short for that offset or the entry isn't an IP.
  defp from_forwarded_for(conn, hops) do
    entries =
      conn
      |> Plug.Conn.get_req_header("x-forwarded-for")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    idx = length(entries) - 1 - hops

    if idx >= 0 do
      entries |> Enum.at(idx) |> parse_ip()
    end
  end

  defp parse_ip(nil), do: nil

  defp parse_ip(s) do
    # Accept a bracketed IPv6 literal ("[2001:db8::1]"); reject anything with a port or
    # other junk by letting :inet.parse_address fail (→ nil → safe fallback).
    s = s |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(s)) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end
end
