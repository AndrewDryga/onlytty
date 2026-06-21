defmodule OnlyttyWeb.Router do
  use OnlyttyWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # WebSocket upgrades, the health check, and the static viewer page set their own
  # content type and do no negotiation — so this pipeline is empty. (An `:accepts`
  # plug here would 406 a browser sending `Accept: text/html`.)
  pipeline :raw do
  end

  scope "/api", OnlyttyWeb do
    pipe_through :api

    post "/sessions", SessionController, :create
    # Any other verb on the defined path → 405 (not a bare 404 for an unknown route).
    match :*, "/sessions", SessionController, :method_not_allowed
  end

  scope "/", OnlyttyWeb do
    pipe_through :raw

    # OnlyTTY marketing site (server-rendered, indexable).
    get "/", PageController, :home
    get "/tools", PageController, :tools
    get "/control/:slug", PageController, :tool
    get "/terms", PageController, :terms
    get "/privacy", PageController, :privacy
    get "/acceptable-use", PageController, :acceptable_use
    get "/sitemap.xml", PageController, :sitemap

    get "/healthz", SessionController, :healthz
    # Aggregate operator metrics (Prometheus text). Firewall it — never public.
    get "/metrics", MetricsController, :index
    get "/s/:id", SessionController, :viewer

    # Raw WebSockets (WebSock behaviour), upgraded in the controller.
    get "/ws/runner/:id", SocketController, :runner
    get "/ws/viewer/:id", SocketController, :viewer
  end
end
