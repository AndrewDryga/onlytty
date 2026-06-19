defmodule RelayWeb.Router do
  use RelayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # WebSocket upgrades, the health check, and the static viewer page set their own
  # content type and do no negotiation — so this pipeline is empty. (An `:accepts`
  # plug here would 406 a browser sending `Accept: text/html`.)
  pipeline :raw do
  end

  scope "/api", RelayWeb do
    pipe_through :api

    post "/sessions", SessionController, :create
  end

  scope "/", RelayWeb do
    pipe_through :raw

    get "/healthz", SessionController, :healthz
    get "/s/:id", SessionController, :viewer

    # Raw WebSockets (WebSock behaviour), upgraded in the controller.
    get "/ws/runner/:id", SocketController, :runner
    get "/ws/viewer/:id", SocketController, :viewer
  end
end
