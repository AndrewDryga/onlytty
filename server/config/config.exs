# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :relay,
  generators: [timestamp_type: :utc_datetime],
  # Per-IP throttle for POST /api/sessions. :infinity disables it. Tunable at
  # runtime via RELAY_RATELIMIT_MAX / RELAY_RATELIMIT_WINDOW (see runtime.exs).
  rate_limit_max: 30,
  rate_limit_window_ms: 60_000

# Configures the endpoint
config :relay, RelayWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: RelayWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Relay.PubSub,
  live_view: [signing_salt: "+4xex4VK"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Backend-only error reporting. No-ops unless SENTRY_DSN is set, so dev/test/CI
# never report. DSN, release, and environment are read from SENTRY_DSN /
# SENTRY_RELEASE / SENTRY_ENVIRONMENT. We capture crashes via Sentry.LoggerHandler
# only (see Relay.Application) and attach no request context — so events never
# carry IPs, request bodies, or other PII; terminal IO is E2E and never on the server.
config :sentry,
  environment_name: config_env(),
  enable_source_code_context: false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
