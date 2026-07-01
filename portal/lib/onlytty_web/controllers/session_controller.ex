defmodule OnlyTTYWeb.SessionController do
  @moduledoc """
  Plain HTTP endpoints: create a session, health check, and serve the static
  viewer page. WebSocket upgrades live in `OnlyTTYWeb.SocketController`.
  """

  use OnlyTTYWeb, :controller

  alias OnlyTTY.SessionStore

  @doc """
  `POST /api/sessions` — create a session, or re-claim an existing one.

  The runner generates its own `id` and `runner_token` (each URL-safe, >= 120 bits)
  and sends them in the JSON body, so it can re-establish the SAME session on any
  node after a node loss/deploy. Both are required. Optional `ttl_seconds` (default
  `0` = no expiry; a positive value is floored at 60s and capped by the optional
  `ONLYTTY_MAX_TTL`). Idempotent: re-posting the same id with the matching token
  attaches to the live session (keeping its expiry); a wrong token for an existing
  id is a 401. Responds 201 with `{id, runner_token, expires_at}`.
  """
  def create(conn, params) do
    # The per-IP throttle runs in the endpoint (OnlyTTYWeb.RateLimitGuard) ahead of
    # Plug.Parsers, so by the time we get here the request is within the limit.
    with {:ok, id} <- id_param(params),
         {:ok, token} <- token_param(params),
         {:ok, ttl} <- ttl_param(params) do
      create_session(conn, id, token, ttl)
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})
    end
  end

  @doc "`/api/sessions` with a method other than POST → 405."
  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> put_status(:method_not_allowed)
    |> json(%{error: "method not allowed; use POST"})
  end

  defp create_session(conn, id, token, ttl) do
    case SessionStore.create_or_attach(id, token, ttl_seconds: ttl) do
      {:ok, session} ->
        conn
        |> put_status(:created)
        |> json(%{
          id: session.id,
          runner_token: session.runner_token,
          expires_at: session.expires_at
        })

      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "session id is held by another runner"})

      {:error, :at_capacity} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "relay at capacity, try again later"})

      {:error, :unavailable} ->
        # A live session with this id was racing teardown; the runner retries.
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "session is settling, try again"})
    end
  end

  @doc """
  `GET /healthz` — liveness probe. Returns 503 while the node is draining (SIGTERM),
  so the load balancer stops routing new connections here during a deploy.
  """
  def healthz(conn, _params) do
    {status, body} = if OnlyTTY.Drain.draining?(), do: {503, "draining"}, else: {200, "ok"}

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
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

  # The runner supplies a URL-safe id + runner token (it generates both, >= 120 bits,
  # so it can re-claim the same session after a node loss). Bound the length so a
  # client can't push absurd payloads; reject anything non-URL-safe.
  defp id_param(params), do: token_str(params, "id")
  defp token_param(params), do: token_str(params, "runner_token")

  defp token_str(params, key) do
    case params do
      %{^key => s} when is_binary(s) ->
        if byte_size(s) in 16..128 and s =~ ~r/\A[A-Za-z0-9_-]+\z/,
          do: {:ok, s},
          else: {:error, "#{key} is invalid"}

      _ ->
        {:error, "#{key} is required"}
    end
  end

  # `ttl_seconds`, when present, must be a JSON integer. Anything else is a 400
  # rather than a silent default (the CLI always sends an int). Missing → nil, and
  # the store applies the default + clamping.
  defp ttl_param(%{"ttl_seconds" => ttl}) when is_integer(ttl), do: {:ok, ttl}
  defp ttl_param(%{"ttl_seconds" => _}), do: {:error, "ttl_seconds must be an integer"}
  defp ttl_param(_), do: {:ok, nil}
end
