defmodule OnlyttyWeb.SocketController do
  @moduledoc """
  Upgrades `GET /ws/runner/:id` and `GET /ws/viewer/:id` to raw WebSockets via
  the `WebSock` behaviour (no Phoenix Channels — we relay opaque binary frames).

  Auth and session existence are enforced *here, before the upgrade*, because
  `WebSock.init/1` only runs after the handshake has already succeeded:

    * unknown / expired session  -> 404 (the handshake fails; no socket opens)
    * runner with wrong/missing token -> 401

  The single-viewer lock is the one rejection that happens after upgrade: the
  viewer socket sends `{"t":"busy"}` then closes (handled in `OnlyttySocket`).
  """

  use OnlyttyWeb, :controller

  alias Onlytty.{Session, SessionStore}

  # Cap a single frame so a client can't OOM the relay (Bandit enforces this at the
  # frame parser, before any payload is buffered, and closes with 1009 on violation —
  # see OnlyttySocket.terminate/2, which counts the reject). Terminal frames are tiny;
  # 1 MiB is generous headroom for a large paste / screen repaint. Tunable at runtime
  # via ONLYTTY_MAX_FRAME_BYTES for operators who want a tighter covert-tunnel bound.
  @default_max_frame_size 1024 * 1024
  # Socket read idle timeout (ms). The Session enforces the real idle/TTL policy;
  # this just reaps dead TCP connections.
  @socket_timeout 120_000

  defp max_frame_size do
    Application.get_env(:onlytty, :max_frame_bytes, @default_max_frame_size)
  end

  def runner(conn, %{"id" => id}) do
    with {:ok, pid} <- SessionStore.lookup(id),
         :ok <- authorize_runner(conn, pid) do
      upgrade(conn, %{session: pid, id: id, role: :runner})
    else
      :error -> reject(conn, 404, "unknown session")
      :unauthorized -> reject(conn, 401, "unauthorized")
    end
  end

  def viewer(conn, %{"id" => id}) do
    case SessionStore.lookup(id) do
      {:ok, pid} -> upgrade(conn, %{session: pid, id: id, role: :viewer})
      :error -> reject(conn, 404, "unknown session")
    end
  end

  defp upgrade(conn, state) do
    conn
    |> WebSockAdapter.upgrade(OnlyttyWeb.OnlyttySocket, state,
      max_frame_size: max_frame_size(),
      timeout: @socket_timeout
    )
    |> halt()
  end

  defp authorize_runner(conn, session) do
    token = Session.runner_token(session)

    case get_req_header(conn, "authorization") do
      ["Bearer " <> presented] -> if secure_equal?(presented, token), do: :ok, else: :unauthorized
      _ -> :unauthorized
    end
  end

  # Constant-time compare so a wrong token can't be guessed by timing.
  defp secure_equal?(a, b) when is_binary(a) and is_binary(b) do
    :crypto.hash_equals(a, b)
  rescue
    # hash_equals raises on length mismatch on some OTPs; treat as not-equal.
    ArgumentError -> false
  end

  defp reject(conn, status, message) do
    case status do
      401 -> Onlytty.Metrics.inc(:upgrade_unauthorized)
      404 -> Onlytty.Metrics.inc(:upgrade_not_found)
      _ -> :ok
    end

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
    |> halt()
  end
end
