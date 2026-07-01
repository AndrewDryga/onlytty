import Config

# Do not print debug messages in production
config :logger, level: :info

# The end-to-end secret lives in the URL fragment, but the page itself (and thus the
# Web Crypto API the viewer needs) must be served over TLS. Redirect http→https and
# set HSTS. `rewrite_on` trusts the x-forwarded-proto from a TLS-terminating proxy,
# so requests already arriving as https are not redirected.
config :onlytty, OnlyTTYWeb.Endpoint, force_ssl: [hsts: true, rewrite_on: [:x_forwarded_proto]]

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
