defmodule RelayWeb.Router do
  use RelayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # WebSocket upgrades and the static viewer page don't negotiate content types;
  # they go through a bare pipeline.
  pipeline :raw do
    plug :accepts, ["*/*"]
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
