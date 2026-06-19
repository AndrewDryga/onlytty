defmodule Relay.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RelayWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:relay, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Relay.PubSub},
      # In-memory session registry + one supervised GenServer per session. The
      # supervisor is capped so unauthenticated session creation cannot exhaust the
      # node (see Relay.SessionStore.create/1); tune with RELAY_MAX_SESSIONS.
      {Registry, keys: :unique, name: Relay.Registry},
      {DynamicSupervisor,
       name: Relay.SessionSupervisor,
       strategy: :one_for_one,
       max_children: Application.get_env(:relay, :max_sessions, 2_000)},
      # Start to serve requests, typically the last entry
      RelayWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Relay.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RelayWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
