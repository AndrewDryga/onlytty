defmodule OnlyttyWeb.SessionController do
  @moduledoc """
  Plain HTTP endpoints: create a session, health check, and serve the static
  viewer page. WebSocket upgrades live in `OnlyttyWeb.SocketController`.
  """

  use OnlyttyWeb, :controller

  alias Onlytty.SessionStore

  @doc """
  `POST /api/sessions` — create a session.

  Optional JSON body `{"ttl_seconds": int}` (default 1800, clamped to
  [60, 604800] by the store). A present-but-non-integer `ttl_seconds` is a 400
  rather than a silent default. Responds 201 with the id, the runner token, and
  the absolute expiry in unix seconds.
  """
  def create(conn, params) do
    # Throttle the unauthenticated create path by client IP before doing any work,
    # so a flood can't fill the session pool. conn.remote_ip is the direct peer; see
    # the README's proxy note for deployments where that is the reverse proxy.
    case Onlytty.RateLimit.check(conn.remote_ip) do
      {:error, retry_after} ->
        Onlytty.Metrics.inc(:rate_limit_rejects)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(:too_many_requests)
        |> json(%{error: "rate limited; slow down and retry"})

      :ok ->
        case ttl_param(params) do
          {:error, message} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: message})

          {:ok, ttl} ->
            create_session(conn, ttl)
        end
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
