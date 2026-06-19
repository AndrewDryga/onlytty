defmodule Relay.Session do
  @moduledoc """
  One GenServer per live session. It owns the session's lifecycle and the
  control plane only: who the runner is, who the viewer is, the single-viewer
  lock, and the TTL / idle timers. It deliberately never sees terminal IO —
  binary frames are relayed socket-to-socket directly (see `Relay.SocketState`),
  so this process is off the hot path and could not read frame contents if it
  tried.

  State per session:
    * `id`           — URL-safe session id (also the viewer connect capability)
    * `runner_token` — bearer token authorizing the privileged runner socket
    * `created_at` / `expires_at` — unix seconds; `expires_at` drives the TTL
    * `runner` / `viewer` — the connected socket pids (or nil), each monitored
    * `locked` — single-viewer lock (default true): at most one viewer
    * `idle_ms` — close the session after this long with no runner traffic

  Sockets talk to their peer through messages this process hands out:
    * `{:relay_control, json_binary}` — a control-plane JSON frame to send
    * `{:set_peer, pid}` — your peer just arrived; relay binary directly to it
    * `:peer_left` — your peer is gone; drop binary until a new peer arrives
    * `{:close, code, reason_text}` — close your socket with this WS close code
  """

  use GenServer, restart: :temporary

  require Logger

  # WebSocket close codes. 4000-4999 is the private-use range; we use them so a
  # client can distinguish *why* a session ended without us parsing any payload.
  @close_bye 4000

  # --- client API ------------------------------------------------------------

  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: Relay.SessionStore.via(id))
  end

  @doc "Register the calling process as the runner. Returns the hello snapshot."
  @spec join_runner(pid()) :: {:ok, %{viewers: non_neg_integer(), locked: boolean()}}
  def join_runner(session) do
    GenServer.call(session, {:join_runner, self()})
  end

  @doc """
  Register the calling process as a viewer. Returns the hello snapshot, or
  `:busy` when the single-viewer lock is already held.
  """
  @spec join_viewer(pid()) ::
          {:ok, %{viewers: non_neg_integer(), locked: boolean(), runner_present: boolean()}}
          | :busy
  def join_viewer(session) do
    GenServer.call(session, {:join_viewer, self()})
  end

  @doc "Reset the idle timer; called by the runner socket on runner traffic."
  @spec runner_active(pid()) :: :ok
  def runner_active(session) do
    GenServer.cast(session, :runner_active)
  end

  @doc "Fetch the session's runner token, for authorizing the runner socket."
  @spec runner_token(pid()) :: String.t()
  def runner_token(session) do
    GenServer.call(session, :runner_token)
  end

  # --- server ----------------------------------------------------------------

  @impl true
  def init(opts) do
    now = System.system_time(:second)
    ttl = Keyword.fetch!(opts, :ttl_seconds)
    idle_ms = Keyword.fetch!(opts, :idle_ms)

    state = %{
      id: Keyword.fetch!(opts, :id),
      runner_token: Keyword.fetch!(opts, :runner_token),
      created_at: now,
      expires_at: now + ttl,
      runner: nil,
      runner_ref: nil,
      viewer: nil,
      viewer_ref: nil,
      locked: Keyword.get(opts, :locked, true),
      idle_ms: idle_ms,
      idle_timer: nil,
      ttl_timer: Process.send_after(self(), :ttl_expired, ttl * 1000)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:runner_token, _from, state) do
    {:reply, state.runner_token, state}
  end

  def handle_call({:join_runner, pid}, _from, state) do
    # A runner may reconnect to the same id; replace any previous runner socket.
    state =
      state
      |> maybe_demonitor(:runner)
      |> Map.merge(%{runner: pid, runner_ref: Process.monitor(pid)})
      |> reset_idle_timer()

    # Tell each side about the other so binary can flow immediately, and let a
    # waiting viewer know its peer (the runner) is now present.
    if state.viewer do
      send(state.viewer, {:set_peer, pid})
      send(pid, {:set_peer, state.viewer})
      send(state.viewer, {:relay_control, control(:peer_join)})
    end

    Logger.info("relay session #{state.id}: runner joined")
    {:reply, {:ok, hello_snapshot(state)}, state}
  end

  def handle_call({:join_viewer, pid}, _from, state) do
    cond do
      state.locked and is_pid(state.viewer) ->
        # Single-viewer lock held: caller will send {"t":"busy"} and close.
        {:reply, :busy, state}

      true ->
        state =
          state
          |> Map.merge(%{viewer: pid, viewer_ref: Process.monitor(pid)})

        if state.runner do
          # Let both sides relay binary directly, and tell the runner a viewer
          # arrived so it can send HELLO + replay over the binary channel.
          send(state.runner, {:set_peer, pid})
          send(pid, {:set_peer, state.runner})
          send(state.runner, {:relay_control, control(:peer_join)})
        end

        Logger.info("relay session #{state.id}: viewer joined")

        snapshot =
          state
          |> hello_snapshot()
          |> Map.put(:runner_present, is_pid(state.runner))

        {:reply, {:ok, snapshot}, state}
    end
  end

  @impl true
  def handle_cast(:runner_active, state) do
    {:noreply, reset_idle_timer(state)}
  end

  @impl true
  def handle_info(:ttl_expired, state) do
    close_all(state, @close_bye, "expired")
    {:stop, :normal, state}
  end

  def handle_info(:idle_expired, state) do
    close_all(state, @close_bye, "idle")
    {:stop, :normal, state}
  end

  # A monitored socket went away.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{runner_ref: ref} = state) do
    # Runner dropped: tell the viewer its peer left, but keep the session alive
    # until TTL so the runner can reconnect to the same id.
    if state.viewer, do: send(state.viewer, {:relay_control, control(:peer_left)})
    if state.viewer, do: send(state.viewer, :peer_left)
    Logger.info("relay session #{state.id}: runner left")
    {:noreply, %{state | runner: nil, runner_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{viewer_ref: ref} = state) do
    # Viewer dropped: free the slot and tell the runner its peer left.
    if state.runner, do: send(state.runner, {:relay_control, control(:peer_left)})
    if state.runner, do: send(state.runner, :peer_left)
    Logger.info("relay session #{state.id}: viewer left")
    {:noreply, %{state | viewer: nil, viewer_ref: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- helpers ---------------------------------------------------------------

  defp hello_snapshot(state) do
    %{viewers: if(state.viewer, do: 1, else: 0), locked: state.locked}
  end

  defp maybe_demonitor(state, :runner) do
    if state.runner_ref, do: Process.demonitor(state.runner_ref, [:flush])
    state
  end

  defp reset_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: Process.send_after(self(), :idle_expired, state.idle_ms)}
  end

  defp close_all(state, code, reason) do
    msg = {:close, code, reason}
    if state.runner, do: send(state.runner, msg)
    if state.viewer, do: send(state.viewer, msg)
    Logger.info("relay session #{state.id}: closing (#{reason})")
  end

  # Control-plane JSON, metadata only — never any terminal content.
  defp control(:peer_join), do: Jason.encode!(%{t: "peer_join"})
  defp control(:peer_left), do: Jason.encode!(%{t: "peer_left"})
end
