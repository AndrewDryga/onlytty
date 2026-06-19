defmodule RelayWeb.SessionController do
  @moduledoc """
  Plain HTTP endpoints: create a session, health check, and serve the static
  viewer page. WebSocket upgrades live in `RelayWeb.SocketController`.
  """

  use RelayWeb, :controller

  alias Relay.SessionStore

  @doc """
  `POST /api/sessions` — create a session.

  Optional JSON body `{"ttl_seconds": int}` (default 1800, clamped to
  [60, 86400] by the store). Responds 201 with the id, the runner token, and
  the absolute expiry in unix seconds.
  """
  def create(conn, params) do
    case SessionStore.create(ttl_seconds: ttl_param(params)) do
      {:ok, session} ->
        conn
        |> put_status(:created)
        |> json(%{
          id: session.id,
          runner_token: session.runner_token,
          expires_at: session.expires_at
        })

      {:error, :at_capacity} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "relay at capacity, try again later"})
    end
  end

  @doc "`GET /healthz` — liveness probe."
  def healthz(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end

  @doc """
  `GET /s/:id` — serve the viewer page. The page is static and self-contained;
  it does not require the session to exist (it reports missing/expired itself),
  so we just send the file. The id and the secret fragment are read client-side.
  """
  def viewer(conn, _params) do
    path = Path.join(:code.priv_dir(:relay), "static/viewer.html")

    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, path)
  end

  # Accept ttl_seconds as an int or a numeric string; ignore anything else and
  # let the store apply the default. The store does the clamping.
  defp ttl_param(%{"ttl_seconds" => ttl}) when is_integer(ttl), do: ttl

  defp ttl_param(%{"ttl_seconds" => ttl}) when is_binary(ttl) do
    case Integer.parse(ttl) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp ttl_param(_), do: nil
end
