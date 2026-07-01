defmodule OnlyTTYWeb.SecurityHeaders do
  @moduledoc """
  Hardening headers on every response — most importantly a Content-Security-Policy
  that is strict for scripts (the part that matters), with one deliberate exception
  for styles (called out below).

  The viewer is the trust boundary: it is served by the (untrusted) relay host and
  could otherwise be swapped to exfiltrate the URL `#fragment` that carries the
  session secret. `script-src 'self'` (no `'unsafe-inline'`, no `eval`) is the
  load-bearing directive — it stops injected or inline JS from reading the
  fragment. `style-src` keeps `'unsafe-inline'` because the vendored xterm terminal
  applies inline styles to the DOM at runtime (verified: dropping it breaks the
  viewer); it's a far weaker vector — styles can't execute JS or read the fragment.
  Everything else is same-origin only under `default-src 'none'`.

  The public marketing pages (and only those — they opt in via
  `conn.private[:site_csp]` in `PageController`) get a slightly looser variant that
  also allows the Mixpanel analytics script and its API host. The viewer and API
  always get the strict policy, so no tracker can be loaded where the secret lives.

  Set via `register_before_send/2` so the headers also land on static-asset
  responses, which `Plug.Static` sends before any later plug would run.
  """
  @behaviour Plug
  import Plug.Conn

  @csp Enum.join(
         [
           "default-src 'none'",
           "script-src 'self'",
           "style-src 'self' 'unsafe-inline'",
           "img-src 'self' data:",
           "connect-src 'self'",
           "manifest-src 'self'",
           "base-uri 'none'",
           "form-action 'none'",
           "frame-ancestors 'none'"
         ],
         "; "
       )

  # Marketing-page variant: additionally allow the Mixpanel analytics script — the
  # first-party loader (/assets/mixpanel.js, still script-src 'self') pulls the
  # library from cdn.mxpnl.com and sends events to api.mixpanel.com. Applied ONLY to
  # PageController responses (conn.private[:site_csp]); the terminal viewer keeps the
  # strict @csp above, so a tracker there could never reach off-origin to leak the
  # #fragment.
  @csp_site Enum.join(
              [
                "default-src 'none'",
                "script-src 'self' https://cdn.mxpnl.com",
                "style-src 'self' 'unsafe-inline'",
                "img-src 'self' data: https://api.mixpanel.com",
                "connect-src 'self' https://api.mixpanel.com https://api-js.mixpanel.com",
                "manifest-src 'self'",
                "base-uri 'none'",
                "form-action 'none'",
                "frame-ancestors 'none'"
              ],
              "; "
            )

  @permissions_policy "camera=(), microphone=(), geolocation=(), display-capture=(), payment=(), usb=()"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      conn
      |> put_resp_header("content-security-policy", csp_for(conn))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("x-frame-options", "DENY")
      |> put_resp_header("permissions-policy", @permissions_policy)
    end)
  end

  # Marketing pages (PageController) opt in via conn.private[:site_csp]; everything
  # else — viewer, API, sockets, static, health — gets the strict same-origin policy.
  defp csp_for(%Plug.Conn{private: %{site_csp: true}}), do: @csp_site
  defp csp_for(_conn), do: @csp
end
