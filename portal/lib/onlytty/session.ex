defmodule OnlyTTY.Session do
  @moduledoc """
  One GenServer per live session. It owns the session's lifecycle and the
  control plane only: who the runner is, which viewers are attached, the
  single-viewer lock, and the TTL / idle timers. It deliberately never sees
  terminal IO — binary frames are relayed socket-to-socket directly (see
  `OnlyTTYWeb.OnlyTTYSocket`), so this process is off the hot path and could not
  read frame contents if it tried.

  State per session:
    * `id`           — URL-safe session id (also the viewer connect capability)
    * `runner_token` — bearer token authorizing the privileged runner socket
    * `created_at` / `expires_at` — unix seconds; `expires_at` drives the TTL
    * `runner` — the connected runner socket pid (or nil), monitored
    * `viewers` — a `%{pid => monitor_ref}` map of attached viewer sockets. A set,
      not a single slot, so an unlocked session can hold several viewers without
      overwriting one another or leaking a monitor. Locked (the default) still
      admits at most one.
    * `locked` — single-viewer lock (default true): at most one viewer
    * `idle_ms` — close the session after this long with no runner traffic

  Sockets talk to their peers through messages this process hands out. A socket's
  "peer set" is who it relays binary to: the runner's peers are every viewer (so
  output broadcasts to all), and each viewer's peer is the runner.
    * `{:onlytty_control, json_binary}` — a control-plane JSON frame to send
    * `{:add_peer, pid}` — add `pid` to your peer set; relay binary to it too
    * `{:del_peer, pid}` — drop `pid` from your peer set
    * `{:close, code, reason_text}` — close your socket with this WS close code

  NOTE: arbitrating *input control* among multiple viewers (who may type) is a
  runner/end-to-end concern, not this relay's — the relay only ever forwards
  opaque ciphertext and cannot tell an input frame from a control frame. This
  module models the viewer set; a multi-viewer control-handoff protocol is a
  deferred product decision, which is why `locked: true` remains the default.
  """

  use GenServer, restart: :temporary

  require Logger

  # WebSocket close codes. 4000-4999 is the private-use range; we use them so a
  # client can distinguish *why* a session ended without us parsing any payload.
  @close_bye 4000

  # Reap a session with no runner attached — one whose runner never connected, or
  # whose runner dropped and didn't reconnect — so an empty session can't pin a
  # process and the single-session/lock budget until its (possibly long) TTL.
  # Armed at init and re-armed on runner drop; cancelled the moment a runner joins.
  @unconnected_ms 120_000

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
    GenServer.start_link(__MODULE__, opts, name: OnlyTTY.SessionStore.name(id))
  end

  @doc "Register the calling process as the runner. Returns the hello snapshot."
  @spec join_runner(pid()) ::
          {:ok, %{viewers: non_neg_integer(), locked: boolean(), expires_at: integer()}}
  def join_runner(session) do
    GenServer.call(session, {:join_runner, self()})
  end

  @doc """
  Register the calling process as a viewer. Returns the hello snapshot, or
  `:busy` when the single-viewer lock is already held.
  """
  @spec join_viewer(pid()) ::
          {:ok,
           %{
             viewers: non_neg_integer(),
             locked: boolean(),
             expires_at: integer(),
             runner_present: boolean()
           }}
          | :busy
  def join_viewer(session) do
    GenServer.call(session, {:join_viewer, self()})
  end

  @doc "Reset the idle timer; called by the runner socket on runner traffic."
  @spec runner_active(pid()) :: :ok
  def runner_active(session) do
    GenServer.cast(session, :runner_active)
  end

  @doc "Close the whole session and all connected sockets with a relay-visible reason."
  @spec close(pid(), String.t()) :: :ok
  def close(session, reason) when is_binary(reason) do
    GenServer.cast(session, {:close, reason})
  end

  @doc """
  Nudge connected sockets that the relay node is going away (a deploy drain), so they
  reconnect elsewhere now. The session stays up for the drain grace; the sockets break
  when the node actually stops, by which point clients have migrated.
  """
  @spec drain(pid()) :: :ok
  def drain(session), do: GenServer.cast(session, :drain)

  @doc "Fetch the session's runner token, for authorizing the runner socket."
  @spec runner_token(pid()) :: String.t()
  def runner_token(session) do
    GenServer.call(session, :runner_token)
  end

  @doc "Constant-time check that `presented` matches this session's runner token."
  @spec valid_runner_token?(pid(), String.t()) :: boolean()
  def valid_runner_token?(session, presented) when is_binary(presented) do
    GenServer.call(session, {:valid_runner_token?, presented})
  end

  @doc "The session's absolute expiry (unix seconds; 0 = no expiry)."
  @spec expires_at(pid()) :: integer()
  def expires_at(session) do
    GenServer.call(session, :expires_at)
  end

  # --- server ----------------------------------------------------------------

  @impl true
  def init(opts) do
    now = System.system_time(:second)
    ttl = Keyword.fetch!(opts, :ttl_seconds)
    idle_ms = Keyword.fetch!(opts, :idle_ms)
    unconnected_ms = Keyword.get(opts, :unconnected_ms, @unconnected_ms)

    state = %{
      id: Keyword.fetch!(opts, :id),
      runner_token: Keyword.fetch!(opts, :runner_token),
      created_at: now,
      expires_at: if(ttl > 0, do: now + ttl, else: 0),
      runner: nil,
      runner_ref: nil,
      viewers: %{},
      locked: Keyword.get(opts, :locked, true),
      idle_ms: idle_ms,
      idle_timer: nil,
      unconnected_ms: unconnected_ms,
      ttl_timer: if(ttl > 0, do: Process.send_after(self(), :ttl_expired, ttl * 1000), else: nil),
      unconnected_timer: Process.send_after(self(), :reap_unconnected, unconnected_ms)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:runner_token, _from, state) do
    {:reply, state.runner_token, state}
  end

  def handle_call({:valid_runner_token?, presented}, _from, state) do
    {:reply, secure_equal?(presented, state.runner_token), state}
  end

  def handle_call(:expires_at, _from, state) do
    {:reply, state.expires_at, state}
  end

  def handle_call({:join_runner, pid}, _from, state) do
    # A runner may reconnect to the same id; replace any previous runner socket.
    if state.unconnected_timer, do: Process.cancel_timer(state.unconnected_timer)

    # Fence a displaced runner: close the old socket so its stale peer wiring dies and
    # a zombie can't keep injecting frames into the viewer after being replaced. We
    # demonitor it (:flush) below, so its :DOWN won't trip the runner-gone grace.
    old = state.runner
    if is_pid(old) and old != pid, do: send(old, {:close, @close_bye, "replaced"})

    state =
      state
      |> maybe_demonitor(:runner)
      |> Map.merge(%{runner: pid, runner_ref: Process.monitor(pid), unconnected_timer: nil})
      |> reset_idle_timer()

    # Wire the runner to every attached viewer so binary flows both ways immediately,
    # and let each waiting viewer know its peer (the runner) is now present. On a
    # reconnect, first drop the displaced runner from each viewer's peer set so a
    # viewer never keeps sending input to the fenced zombie.
    for {viewer, _ref} <- state.viewers do
      if is_pid(old) and old != pid, do: send(viewer, {:del_peer, old})
      send(viewer, {:add_peer, pid})
      send(pid, {:add_peer, viewer})
      send(viewer, {:onlytty_control, control(:peer_join)})
    end

    OnlyTTY.Metrics.inc(:runners_connected)
    Logger.info("relay session #{short(state.id)}: runner joined")
    {:reply, {:ok, hello_snapshot(state)}, state}
  end

  def handle_call({:join_viewer, pid}, _from, state) do
    cond do
      state.locked and map_size(state.viewers) > 0 ->
        # Single-viewer lock held: caller will send {"t":"busy"} and close.
        OnlyTTY.Metrics.inc(:viewer_busy_rejects)
        {:reply, :busy, state}

      true ->
        state = %{state | viewers: Map.put(state.viewers, pid, Process.monitor(pid))}

        if state.runner do
          # Let both sides relay binary directly, and tell the runner a viewer
          # arrived so it can send HELLO + replay over the binary channel.
          send(state.runner, {:add_peer, pid})
          send(pid, {:add_peer, state.runner})
          send(state.runner, {:onlytty_control, control(:peer_join)})
        end

        OnlyTTY.Metrics.inc(:viewers_connected)
        Logger.info("relay session #{short(state.id)}: viewer joined")

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

  def handle_cast({:close, reason}, state) do
    close_all(state, @close_bye, reason)
    {:stop, :normal, state}
  end

  def handle_cast(:drain, state) do
    # The node is shutting down: tell each side to reconnect elsewhere. We don't close
    # the sockets — traffic keeps flowing over this node until it actually stops.
    msg = {:onlytty_control, control(:going_away)}
    if state.runner, do: send(state.runner, msg)
    for {viewer, _ref} <- state.viewers, do: send(viewer, msg)
    {:noreply, state}
  end

  @impl true
  def handle_info(:ttl_expired, state) do
    OnlyTTY.Metrics.inc(:sessions_ttl_expired)
    close_all(state, @close_bye, "expired")
    {:stop, :normal, state}
  end

  def handle_info(:idle_expired, state) do
    OnlyTTY.Metrics.inc(:sessions_idle_expired)
    close_all(state, @close_bye, "idle")
    {:stop, :normal, state}
  end

  def handle_info(:reap_unconnected, %{runner: nil} = state) do
    OnlyTTY.Metrics.inc(:sessions_ttl_expired)
    close_all(state, @close_bye, "expired")
    {:stop, :normal, state}
  end

  def handle_info(:reap_unconnected, state), do: {:noreply, state}

  # A monitored socket went away. The runner clause is first, so it matches runner
  # DOWNs; the general viewer clause below then only sees non-runner DOWNs.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{runner_ref: ref} = state) do
    # Runner dropped: tell every viewer its peer left and drop the runner from their
    # peer sets, and keep the session alive for a short grace so the runner can
    # reconnect to the same id. Re-arm the unconnected reap (cancelled again on
    # reconnect) so an empty session can't hold the process/lock budget until idle/TTL.
    runner = state.runner

    for {viewer, _ref} <- state.viewers do
      send(viewer, {:onlytty_control, control(:peer_left)})
      send(viewer, {:del_peer, runner})
    end

    Logger.info("relay session #{short(state.id)}: runner left")
    if state.unconnected_timer, do: Process.cancel_timer(state.unconnected_timer)
    timer = Process.send_after(self(), :reap_unconnected, state.unconnected_ms)
    {:noreply, %{state | runner: nil, runner_ref: nil, unconnected_timer: timer}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    if Map.get(state.viewers, pid) == ref do
      # A viewer dropped: free only that viewer's slot and drop it from the runner's
      # peer set. Tell the runner its peer left only when the LAST viewer is gone, so
      # a runner streaming to several viewers keeps going for the ones that remain.
      viewers = Map.delete(state.viewers, pid)
      if state.runner, do: send(state.runner, {:del_peer, pid})

      if is_pid(state.runner) and map_size(viewers) == 0 do
        send(state.runner, {:onlytty_control, control(:peer_left)})
      end

      Logger.info("relay session #{short(state.id)}: viewer left")
      {:noreply, %{state | viewers: viewers}}
    else
      # A stale monitor for a socket we no longer track — ignore.
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- helpers ---------------------------------------------------------------

  defp hello_snapshot(state) do
    %{
      viewers: map_size(state.viewers),
      locked: state.locked,
      expires_at: state.expires_at
    }
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
    for {viewer, _ref} <- state.viewers, do: send(viewer, msg)
    Logger.info("relay session #{short(state.id)}: closing (#{reason})")
  end

  # Control-plane JSON, metadata only — never any terminal content.
  defp control(:peer_join), do: Jason.encode!(%{t: "peer_join"})
  defp control(:peer_left), do: Jason.encode!(%{t: "peer_left"})
  defp control(:going_away), do: Jason.encode!(%{t: "going_away"})

  # The session id is the viewer connect capability; log only a short prefix so a
  # leaked log can't be used to connect to live sessions.
  defp short(id), do: String.slice(id, 0, 8)

  # Constant-time compare so a wrong token can't be guessed by timing.
  defp secure_equal?(a, b) when is_binary(a) and is_binary(b) do
    :crypto.hash_equals(a, b)
  rescue
    # hash_equals raises on length mismatch on some OTPs; treat as not-equal.
    ArgumentError -> false
  end
end
