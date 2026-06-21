defmodule OnlyttyWeb.SessionController do
  @moduledoc """
  Plain HTTP endpoints: create a session, health check, and serve the static
  viewer page. WebSocket upgrades live in `OnlyttyWeb.SocketController`.
  """

  use OnlyttyWeb, :controller

  alias Onlytty.SessionStore

  @doc """
  `POST /api/sessions` — create a session.

  Optional JSON body `{"ttl_seconds": int}` (default `0` = no expiry; a positive
  value is floored at 60s and capped by the optional `ONLYTTY_MAX_TTL` ceiling). A
  present-but-non-integer `ttl_seconds` is a 400 rather than a silent default.
  Responds 201 with the id, the runner token, and the absolute expiry in unix
  seconds — `0` when the session has no expiry.
  """
  def create(conn, params) do
    # The per-IP throttle runs in the endpoint (OnlyttyWeb.RateLimitGuard) ahead of
    # Plug.Parsers, so by the time we get here the request is within the limit.
    case ttl_param(params) do
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})

      {:ok, ttl} ->
        create_session(conn, ttl)
    end
  end

  @doc "`/api/sessions` with a method other than POST → 405."
  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> put_status(:method_not_allowed)
    |> json(%{error: "method not allowed; use POST"})
  end

  defp create_session(conn, ttl) do
    case SessionStore.create(ttl_seconds: ttl) do
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
    path = Path.join(:code.priv_dir(:onlytty), "static/viewer.html")

    conn
    # The viewer shell is security-sensitive code delivery — never cache it, so the
    # browser always loads the audited bytes (matches the first-party JS policy).
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/html")
    |> send_file(200, path)
  end

  # `ttl_seconds`, when present, must be a JSON integer. Anything else is a 400
  # rather than a silent default (the CLI always sends an int). Missing → nil, and
  # the store applies the default + clamping.
  defp ttl_param(%{"ttl_seconds" => ttl}) when is_integer(ttl), do: {:ok, ttl}
  defp ttl_param(%{"ttl_seconds" => _}), do: {:error, "ttl_seconds must be an integer"}
  defp ttl_param(_), do: {:ok, nil}
end
