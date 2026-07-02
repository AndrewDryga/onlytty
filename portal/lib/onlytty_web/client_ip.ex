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

  The key is bucketed to the client's routing prefix so it can't be sidestepped by
  address rotation: IPv6 is masked to its /64 (the last 4 of the 8 16-bit groups zeroed),
  since a single client is routinely handed a whole /64 — keying on the full /128 would
  let one host rotate through its prefix to dodge "N creates/min per IP" and bloat the
  limiter's ETS table with an entry per address. IPv4 (one address = one host) is
  unchanged. The masking is scoped to the returned key; `conn.remote_ip` is never touched.
  """

  # IPv6 clients get a whole /64; bucket the rate-limit key to that prefix.
  @ipv6_prefix_groups 4

  @doc "The client IP to throttle on, per the configured trusted-proxy hop count."
  @spec resolve(Plug.Conn.t()) :: :inet.ip_address()
  def resolve(%Plug.Conn{} = conn) do
    hops = Application.get_env(:onlytty, :trusted_proxy_hops, 0)

    ip =
      if is_integer(hops) and hops > 0 do
        from_forwarded_for(conn, hops) || conn.remote_ip
      else
        conn.remote_ip
      end

    mask(ip)
  end

  # Bucket an IPv6 address to its /64 (zero groups 5–8); IPv4 is one host, so pass through.
  defp mask({_, _, _, _, _, _, _, _} = ipv6) do
    ipv6
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.map(fn {group, i} -> if i < @ipv6_prefix_groups, do: group, else: 0 end)
    |> List.to_tuple()
  end

  defp mask(ip), do: ip

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
