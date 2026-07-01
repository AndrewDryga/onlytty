defmodule OnlyTTY.MixProject do
  use Mix.Project

  def project do
    [
      app: :onlytty,
      version: "0.4.1",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {OnlyTTY.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8"},
      # Phoenix 1.8.8 still depends on websock_adapter ~> 0.5.3. OnlyTTY always
      # passes max_frame_size explicitly, so 0.6.0's default-limit change is inert here.
      {:websock_adapter, "~> 0.6", override: true},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:libcluster, "~> 3.5"},
      {:bandit, "~> 1.5"},
      # Backend-only error reporting; no-ops unless SENTRY_DSN is set. The config
      # pins Sentry to Hackney instead of Finch to keep one HTTP client dependency.
      {:sentry, "~> 13.2"},
      {:hackney, "~> 4.4"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
