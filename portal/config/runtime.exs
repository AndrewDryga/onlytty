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

# Runtime operational settings are parsed in `Onlytty.Env.runtime_overrides/1` so tests can
# exercise the same process-env path that deployments use:
#   ONLYTTY_DEFAULT_TTL, ONLYTTY_MAX_TTL, ONLYTTY_IDLE_TIMEOUT
#   ONLYTTY_MAX_SESSIONS, ONLYTTY_MAX_FRAME_BYTES, ONLYTTY_ALLOWED_ORIGINS
#   ONLYTTY_RATELIMIT_MAX, ONLYTTY_RATELIMIT_WINDOW
#   ONLYTTY_TRUSTED_PROXY_HOPS, ONLYTTY_METRICS_TOKEN
for {key, value} <- Onlytty.Env.runtime_overrides() do
  config :onlytty, key, value
end

# ONLYTTY_TRUSTED_PROXY_HOPS — number of trusted reverse proxies in front of the relay,
# used to pick the real client IP for the POST /api/sessions rate-limit key.
#   0 (default) — no proxy: key on the direct TCP peer (conn.remote_ip) and ignore
#                 X-Forwarded-For. This is the self-host / bare deployment behavior.
#   1           — the Google HTTPS LB shape: it appends `<client>, <GFE>`, so the client
#                 is the second-to-last X-Forwarded-For entry (one trusted hop).
#   N           — for a chain of N proxies you control (e.g. Cloudflare -> nginx).
# The client IP is read as a FIXED offset from the RIGHT (infra-appended) end of
# X-Forwarded-For, so a client can't shift the read position by spoofing extra left-hand
# entries; a short/malformed header falls back to the peer. See OnlyttyWeb.ClientIP. This
# only affects the rate-limit key — GET /metrics loopback auth still uses the real peer.
#
# ONLYTTY_METRICS_TOKEN — bearer token that lets a remote scraper (e.g. Prometheus
# behind the LB) read GET /metrics. Without it, /metrics is loopback-only; with it,
# a request carrying `Authorization: Bearer <token>` is allowed from any IP. See
# OnlyttyWeb.MetricsAccess. Aggregate counters only — still never expose it broadly.

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

  # BEAM clustering across relay instances. When ONLYTTY_CLUSTER_PROJECT is set (on a
  # GCP MIG), libcluster's GCE strategy lists the project's RUNNING relay instances via
  # the Compute API and connects them as `onlytty@<internal-ip>`. Unset (single node /
  # dev) → no topology, so the relay runs standalone.
  cluster_topologies =
    case System.get_env("ONLYTTY_CLUSTER_PROJECT") do
      project when is_binary(project) and project != "" ->
        [
          onlytty: [
            strategy: Onlytty.Cluster.GCE,
            config: [
              project_id: project,
              cluster_value: System.get_env("ONLYTTY_CLUSTER_VALUE") || "onlytty"
            ]
          ]
        ]

      _ ->
        []
    end

  config :onlytty, :cluster_topologies, cluster_topologies

  # Drain connections gracefully on SIGTERM (a deploy replacing this instance):
  # /healthz → 503, nudge clients to migrate, brief grace, then stop. Prod only so
  # dev/test signal handling is untouched.
  config :onlytty, :drain_on_sigterm, true

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
