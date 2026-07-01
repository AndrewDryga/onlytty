defmodule OnlyTTYWeb.CacheControl do
  @moduledoc """
  Per-path `Cache-Control` for static assets.

  The viewer's first-party JS is security-sensitive *code delivery* — a swapped
  bundle could exfiltrate the URL `#fragment` secret — so it is served `no-store`:
  the browser always re-fetches the audited bytes and a tampered response can never
  be cached or replayed from cache, and the served bytes always match any published
  hash. The vendored, Subresource-Integrity-pinned xterm assets cannot be tampered
  with undetected, so they are `immutable` with a long max-age.

  Set via `register_before_send/2` so it overrides whatever `Plug.Static` set, on
  the static response it sends before any later plug runs. (`viewer.html` is served
  by the controller, which sets `no-store` itself.)
  """
  @behaviour Plug
  import Plug.Conn

  # First-party viewer code — never cache.
  @no_store ~w(/assets/app.js /assets/wire.js /assets/crypto.js /assets/keys.js)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      cond do
        conn.request_path in @no_store ->
          put_resp_header(conn, "cache-control", "no-store")

        String.starts_with?(conn.request_path, "/assets/vendor/") ->
          put_resp_header(conn, "cache-control", "public, max-age=31536000, immutable")

        true ->
          conn
      end
    end)
  end
end
