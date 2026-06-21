defmodule OnlyttyWeb.SecurityHeaders do
  @moduledoc """
  Hardening headers on every response — most importantly a strict
  Content-Security-Policy.

  The viewer is the trust boundary: it is served by the (untrusted) relay host and
  could otherwise be swapped to exfiltrate the URL `#fragment` that carries the
  session secret. `script-src 'self'` (no `'unsafe-inline'`, no `eval`) is the
  load-bearing directive — it stops injected or inline JS from reading the
  fragment. `style-src` allows `'unsafe-inline'` because the viewer and the
  marketing pages use inline styles (a far weaker vector — no script execution);
  everything else is same-origin only under `default-src 'none'`.

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

  @permissions_policy "camera=(), microphone=(), geolocation=(), display-capture=(), payment=(), usb=()"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      conn
      |> put_resp_header("content-security-policy", @csp)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("x-frame-options", "DENY")
      |> put_resp_header("permissions-policy", @permissions_policy)
    end)
  end
end
