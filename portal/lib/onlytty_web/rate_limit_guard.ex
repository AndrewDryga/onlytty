defmodule OnlyttyWeb.RateLimitGuard do
  @moduledoc """
  Per-IP throttle for the unauthenticated `POST /api/sessions` create path,
  enforced in the endpoint *before* `Plug.Parsers` so a flood is rejected before
  any request body is parsed (let alone a session created). Every other request
  passes straight through untouched.

  Reuses `Onlytty.RateLimit` (the same fixed-window limiter the controller used to
  call) and `conn.remote_ip`, the direct peer — see the README's proxy note for
  deployments where that is the reverse proxy.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["api", "sessions"]} = conn, _opts) do
    case Onlytty.RateLimit.check(conn.remote_ip) do
      :ok ->
        conn

      {:error, retry_after} ->
        Onlytty.Metrics.inc(:rate_limit_rejects)
        body = Phoenix.json_library().encode!(%{error: "rate limited; slow down and retry"})

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(429, body)
        |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
