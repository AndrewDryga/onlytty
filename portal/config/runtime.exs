import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/relay start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :onlytty, OnlyttyWeb.Endpoint, server: true
end

# Onlytty session limits, tunable at runtime in every environment.
#   ONLYTTY_DEFAULT_TTL   — TTL (s) for a request that omits one; default 0 = no expiry
#   ONLYTTY_MAX_TTL       — optional hard ceiling on session TTL (s); unset = no ceiling
#   ONLYTTY_IDLE_TIMEOUT  — close a session after this many seconds with no runner
#                         traffic (default 600)
if ttl = System.get_env("ONLYTTY_DEFAULT_TTL") do
  config :onlytty, :default_ttl, Onlytty.Env.pos_int!("ONLYTTY_DEFAULT_TTL", ttl)
end

if max_ttl = System.get_env("ONLYTTY_MAX_TTL") do
  config :onlytty, :max_ttl, Onlytty.Env.pos_int!("ONLYTTY_MAX_TTL", max_ttl)
end

if idle = System.get_env("ONLYTTY_IDLE_TIMEOUT") do
  config :onlytty, :idle_timeout_ms, Onlytty.Env.pos_int!("ONLYTTY_IDLE_TIMEOUT", idle) * 1000
end

# ONLYTTY_MAX_SESSIONS — cap on concurrent in-memory sessions (default 2000). Bounds
# the impact of unauthenticated session creation. Read by the DynamicSupervisor.
if max = System.get_env("ONLYTTY_MAX_SESSIONS") do
  config :onlytty, :max_sessions, Onlytty.Env.pos_int!("ONLYTTY_MAX_SESSIONS", max)
end

# ONLYTTY_MAX_FRAME_BYTES — max size of a single WebSocket frame (default 1048576 = 1
# MiB). Bandit closes the socket with 1009 on violation, before the payload is buffered
# or forwarded — bounds memory use and covert-tunnel abuse. Keep it generous enough for
# a large paste / full-screen redraw (~256KB–1MB).
if bytes = System.get_env("ONLYTTY_MAX_FRAME_BYTES") do
  config :onlytty, :max_frame_bytes, Onlytty.Env.pos_int!("ONLYTTY_MAX_FRAME_BYTES", bytes)
end

# ONLYTTY_ALLOWED_ORIGINS — comma-separated *extra* origins allowed to open a
# *browser viewer* WebSocket (defense-in-depth; the runner WS is never gated). The
# same-host Origin is ALWAYS allowed; this list is additive, so set it only to add
# other hosts, e.g. "https://onlytty.com,https://www.onlytty.com".
if origins = System.get_env("ONLYTTY_ALLOWED_ORIGINS") do
  config :onlytty, :allowed_origins, String.split(origins, ",", trim: true)
end

# Per-IP throttle for POST /api/sessions (defaults: 30 requests / 60s).
#   ONLYTTY_RATELIMIT_MAX     — max creates per window per IP ("0" disables)
#   ONLYTTY_RATELIMIT_WINDOW  — window length in seconds (must be > 0)
if max = System.get_env("ONLYTTY_RATELIMIT_MAX") do
  # "0" intentionally disables the limiter (:infinity); any other value is a positive int.
  rate_max =
    if max == "0", do: :infinity, else: Onlytty.Env.pos_int!("ONLYTTY_RATELIMIT_MAX", max)

  config :onlytty, :rate_limit_max, rate_max
end

if win = System.get_env("ONLYTTY_RATELIMIT_WINDOW") do
  config :onlytty,
         :rate_limit_window_ms,
         Onlytty.Env.pos_int!("ONLYTTY_RATELIMIT_WINDOW", win) * 1000
end

# ONLYTTY_METRICS_TOKEN — bearer token that lets a remote scraper (e.g. Prometheus
# behind the LB) read GET /metrics. Without it, /metrics is loopback-only; with it,
# a request carrying `Authorization: Bearer <token>` is allowed from any IP. See
# OnlyttyWeb.MetricsAccess. Aggregate counters only — still never expose it broadly.
if token = System.get_env("ONLYTTY_METRICS_TOKEN") do
  config :onlytty, :metrics_token, token
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  # DNSCluster polls this to form the BEAM cluster across relay instances. Treat an
  # empty value as unset (→ :ignore in application.ex) so a single instance runs fine.
  dns_cluster_query =
    case System.get_env("DNS_CLUSTER_QUERY") do
      q when is_binary(q) and q != "" -> q
      _ -> nil
    end

  config :onlytty, :dns_cluster_query, dns_cluster_query

  config :onlytty, OnlyttyWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :onlytty, OnlyttyWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :onlytty, OnlyttyWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
