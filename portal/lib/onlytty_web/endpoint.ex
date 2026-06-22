defmodule OnlyttyWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :onlytty

  # No Plug.Session: the relay has no accounts and nothing reads a session cookie.

  # Security hardening (CSP + friends) on every response, static assets included.
  plug OnlyttyWeb.SecurityHeaders

  # Per-path Cache-Control: first-party viewer JS is no-store, vendored assets are
  # immutable (registered before Plug.Static so it overrides the static defaults).
  plug OnlyttyWeb.CacheControl

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :onlytty,
    gzip: false,
    only: OnlyttyWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Throttle POST /api/sessions by client IP BEFORE the body is parsed, so a flood
  # can't spend parser work ahead of being rejected. Other paths pass through.
  plug OnlyttyWeb.RateLimitGuard

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug OnlyttyWeb.Router
end
