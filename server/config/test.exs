import Config

# The relay is exercised end-to-end over real WebSockets in tests, so the
# server must actually listen during the test run.
config :relay, RelayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "oZMlwXqdKb8xdx/PYEDzQD/ZkPxsAKeXGuuvgqxzQThje6N1vmeIkAEdPB5e9xPf",
  server: true

# Shorten the idle timeout so the idle-close path is testable without long sleeps.
config :relay, :idle_timeout_ms, 10 * 60 * 1000

# Disable session-create rate limiting by default; the rate-limit test enables it
# explicitly with a low limit so the rest of the suite isn't throttled.
config :relay, :rate_limit_max, :infinity

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
