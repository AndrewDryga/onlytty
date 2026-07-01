defmodule OnlyttyWeb.RateLimitGuard do
  @moduledoc """
  Per-IP throttle for the unauthenticated `POST /api/sessions` create path,
  enforced in the endpoint *before* `Plug.Parsers` so a flood is rejected before
  any request body is parsed (let alone a session created). Every other request
  passes straight through untouched.

  Reuses `Onlytty.RateLimit` (the same fixed-window limiter the controller used to
  call). The throttle key is `OnlyttyWeb.ClientIP.resolve/1`: the direct peer
  (`conn.remote_ip`) by default, or — when `ONLYTTY_TRUSTED_PROXY_HOPS` is set for a
  reverse-proxied deployment — the real client IP pulled from `X-Forwarded-For` without
  trusting a spoofed header. Behind the Google HTTPS LB that keeps "N creates/min per
  IP" per-client instead of collapsing into one global bucket.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["api", "sessions"]} = conn, _opts) do
    case Onlytty.RateLimit.check(OnlyttyWeb.ClientIP.resolve(conn)) do
      :ok ->
        conn

      {:error, retry_after} ->
        Onlytty.Metrics.inc(:rate_limit_rejects)
        body = Phoenix.json_library().encode!(%{error: "rate limited; slow down and retry"})

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(429, body)
        |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
