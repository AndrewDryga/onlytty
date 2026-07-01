defmodule OnlyTTY.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Backend-only crash reporting, attached only when SENTRY_DSN is set (so dev/
    # test/CI never report). Captures process crashes via the logger; we attach no
    # request context, so events carry no IPs or request bodies. No viewer/browser
    # reporting exists by design — a browser SDK would capture the URL fragment secret.
    if System.get_env("SENTRY_DSN") do
      :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
        config: %{metadata: [:request_id], capture_log_messages: false}
      })
    end

    # Allocate the operator-metrics counter array before anything can bump it.
    OnlyTTY.Metrics.setup()

    # Graceful drain on SIGTERM (deploys): flip /healthz to 503, nudge connected
    # clients to reconnect elsewhere, brief grace, then stop. Prod only (runtime.exs).
    if Application.get_env(:onlytty, :drain_on_sigterm, false), do: OnlyTTY.Drain.install()

    children = [
      OnlyTTYWeb.Telemetry,
      # Forms the BEAM cluster so sessions registered under `:global` resolve across
      # instances. On a GCP MIG, `:cluster_topologies` (runtime.exs) wires libcluster's
      # GCE strategy; empty in dev/test/single-node → the supervisor starts no strategy.
      {Cluster.Supervisor,
       [Application.get_env(:onlytty, :cluster_topologies, []), [name: OnlyTTY.ClusterSupervisor]]},
      {Phoenix.PubSub, name: OnlyTTY.PubSub},
      # One supervised GenServer per session, registered cluster-wide under `:global`
      # by id (so any node can route to a session created on another). The per-node
      # supervisor is capped so unauthenticated session creation cannot exhaust a node
      # (see OnlyTTY.SessionStore.create_or_attach/3); tune with ONLYTTY_MAX_SESSIONS (per node).
      {DynamicSupervisor,
       name: OnlyTTY.SessionSupervisor,
       strategy: :one_for_one,
       max_children: Application.get_env(:onlytty, :max_sessions, 2_000)},
      # Per-IP throttle for unauthenticated session creation (ONLYTTY_RATELIMIT_*).
      OnlyTTY.RateLimit,
      # Start to serve requests, typically the last entry
      OnlyTTYWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: OnlyTTY.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OnlyTTYWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
