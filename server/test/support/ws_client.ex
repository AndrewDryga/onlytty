defmodule Relay.WSClient do
  @moduledoc """
  A tiny `:gun`-based WebSocket test client. It drives the relay over real
  WebSockets so the tests exercise the actual Bandit + WebSock path, not a mock.

  Each helper runs in the calling test process, which becomes gun's owner, so
  `gun_ws` / `gun_upgrade` / `gun_response` messages land in the test's mailbox
  and can be matched with `assert_receive`.
  """

  import ExUnit.Assertions

  @host ~c"127.0.0.1"

  @doc "Open a gun connection to the test endpoint and wait until it is up."
  def open(port) do
    {:ok, pid} = :gun.open(@host, port, %{protocols: [:http], retry: 0})
    {:ok, _protocol} = :gun.await_up(pid, 5000)
    pid
  end

  @doc """
  Upgrade `path` to a WebSocket. Returns `{:ok, stream_ref}` on success or
  `{:error, status}` if the server rejected the handshake with an HTTP status
  (our 401 / 404 rejection path).
  """
  def upgrade(pid, path, headers \\ []) do
    ref = :gun.ws_upgrade(pid, String.to_charlist(path), headers)

    receive do
      {:gun_upgrade, ^pid, ^ref, _protocols, _headers} -> {:ok, ref}
      {:gun_response, ^pid, ^ref, _fin, status, _headers} -> {:error, status}
      {:gun_error, ^pid, ^ref, reason} -> {:error, reason}
    after
      5000 -> flunk("timed out waiting for ws upgrade of #{path}")
    end
  end

  @doc "Upgrade and assert it succeeded, returning the stream ref."
  def connect!(pid, path, headers \\ []) do
    {:ok, ref} = upgrade(pid, path, headers)
    ref
  end

  def send_text(pid, ref, text), do: :gun.ws_send(pid, ref, {:text, text})
  def send_binary(pid, ref, bin), do: :gun.ws_send(pid, ref, {:binary, bin})

  @doc "Await the next text frame and return its decoded JSON map."
  def recv_json(pid, ref, timeout \\ 1000) do
    assert_receive {:gun_ws, ^pid, ^ref, {:text, payload}}, timeout
    Jason.decode!(payload)
  end

  @doc "Await the next binary frame and return its bytes."
  def recv_binary(pid, ref, timeout \\ 1000) do
    assert_receive {:gun_ws, ^pid, ^ref, {:binary, payload}}, timeout
    payload
  end

  @doc "Await a close frame and return `{code, reason}`."
  def recv_close(pid, ref, timeout \\ 1000) do
    assert_receive {:gun_ws, ^pid, ^ref, {:close, code, reason}}, timeout
    {code, reason}
  end

  @doc "Assert no frame arrives within `timeout` ms on this connection."
  def refute_frame(pid, ref, timeout \\ 200) do
    refute_receive {:gun_ws, ^pid, ^ref, _frame}, timeout
  end

  def close(pid), do: :gun.close(pid)
end
