defmodule OnlyTTYWeb.OnlyTTYSocket do
  @moduledoc """
  The `WebSock` handler shared by both ends of a relay. One instance runs per
  connected socket (it *is* the Bandit connection process). Runner and viewer
  behave almost identically here — they differ only in role and in which side's
  traffic resets the idle timer — so a single handler takes a `:role`.

  The contract (PROTOCOL.md):

    * **binary** frames are end-to-end ciphertext. We forward runner output
      verbatim to viewers and, when a new runner opts in, wrap viewer→runner
      frames with the relay-assigned viewer id as metadata. We never parse, log,
      or store the encrypted terminal payload. If there is no peer, we drop (the
      runner buffers; that is the runner's job).
    * **text** frames are the control plane (JSON, metadata only). On connect we
      send `{"t":"hello",...}`. A viewer `{"t":"bye"}` closes that socket; a
      runner `{"t":"bye","reason":"ended"}` closes the whole session.

  Auth and session existence are checked in `OnlyTTYWeb.SocketController` *before*
  the upgrade, so by the time `init/1` runs the session is known to exist and
  (for runners) the token has matched. `init/1` only does the join, which can
  still return `:busy` for a second viewer under the single-viewer lock.

  State: `%{session, id, role, peers, viewer_peers, viewer_id}` — `peers` is a
  `MapSet` of peer socket pids. A viewer's set holds the runner (0 or 1); the
  runner's set holds every attached viewer, so its output broadcasts to all of them.
  Runner sockets also keep a `viewer_peers` id→pid map for targeted control frames.
  The `OnlyTTY.Session` process maintains it via peer messages.
  """

  @behaviour WebSock

  require Logger

  alias OnlyTTY.Session

  @close_normal 1000
  @close_busy 4002
  # 1013 "Try Again Later" (RFC 6455 registered): we force-close a viewer whose
  # socket has stalled and let its output backlog grow. The client's onclose just
  # reconnects and repaints from the runner's ring, so the code is advisory.
  @close_slow 1013
  @relay_viewer_magic "OTV1"

  # Slow-consumer backpressure. A viewer that stops draining its socket applies no
  # backpressure to the runner: relay `send/2` is async, so runner output piles into
  # the viewer process mailbox unbounded and one connection can push a relay node
  # toward OOM. We can't drop *intelligently* (the payload is E2E ciphertext, and a
  # partial drop corrupts the stream), so we count the backlog and evict the whole
  # viewer past a watermark — it reconnects and repaints from the runner's ring.
  #
  # The signal is `message_queue_len`: the count of runner frames still queued behind
  # the one we're processing. It is the only backlog measure BEAM exposes cheaply —
  # queued *bytes* would mean scanning the mailbox, and off-heap refc binaries don't
  # show up in `:memory` either. With the per-frame cap (ONLYTTY_MAX_FRAME_BYTES,
  # default 1 MiB) this bounds the mailbox to at most `max_viewer_queue` frames;
  # real terminal frames are small, so the default 512 targets a few-MiB backlog
  # before eviction (a few × the runner's 256-frame send queue / 256 KiB ring).
  # Operators wanting a tighter memory bound lower ONLYTTY_MAX_VIEWER_QUEUE.
  @default_max_viewer_queue 512

  @impl true
  def init(%{session: session, id: id, role: :runner}) do
    {:ok, snap} = Session.join_runner(session)
    state = base_state(session, id, :runner)
    {:push, [{:text, hello(:runner, snap)}], state}
  end

  def init(%{session: session, id: id, role: :viewer}) do
    case Session.join_viewer(session) do
      {:ok, snap} ->
        state = %{base_state(session, id, :viewer) | viewer_id: snap.viewer_id}
        frames = [{:text, hello(:viewer, snap)}]
        # If the runner is already here, tell the viewer its peer is present.
        frames =
          if snap.runner_present,
            do: frames ++ [{:text, control(:peer_join, snap.viewer_id, snap.viewers)}],
            else: frames

        {:push, frames, state}

      :busy ->
        # Single-viewer lock held: report busy, then close. The runner and the
        # existing viewer are untouched.
        {:stop, :normal, {@close_busy, "busy"}, [{:text, control(:busy)}],
         base_state(session, id, :viewer)}
    end
  end

  @impl true
  # Binary = opaque E2E payload. Runner output broadcasts byte-for-byte to viewers.
  # Viewer input is relay-labeled with viewer id, while the encrypted payload itself
  # remains opaque to the relay.
  def handle_in({data, opcode: :binary}, state) do
    case state.role do
      :runner ->
        Session.runner_active(state.session)
        Enum.each(state.peers, &send(&1, {:onlytty_binary, data}))

      :viewer ->
        Enum.each(state.peers, &send(&1, {:onlytty_binary, state.viewer_id, data}))
    end

    {:ok, state}
  end

  # Text = control plane. Viewer bye closes just that socket; runner bye is the
  # command-exit signal and closes the whole session so viewers see a final state.
  def handle_in({data, opcode: :text}, state) do
    case decode_control(data) do
      {:ok, %{"t" => "bye"} = msg} when state.role == :runner ->
        Session.close(state.session, Map.get(msg, "reason", "closed"))
        {:ok, state}

      {:ok, %{"t" => "to_viewer"} = msg} when state.role == :runner ->
        send_to_viewer(msg, state)
        {:ok, state}

      {:ok, %{"t" => "bye"}} ->
        {:stop, :normal, {@close_normal, "closed"}, state}

      _ ->
        {:ok, state}
    end
  end

  @impl true
  # Peer-to-peer binary relay: push the bytes straight out to our client. This 2-arg
  # message only ever targets a viewer (runner output broadcast + targeted to_viewer),
  # so it is the high-volume path a slow viewer stalls — apply backpressure here.
  def handle_info({:onlytty_binary, data}, state) do
    if slow_viewer?(state) do
      evict_slow_viewer(state)
    else
      {:push, [{:binary, data}], state}
    end
  end

  def handle_info({:onlytty_binary, viewer_id, data}, state) do
    {:push, [{:binary, relay_viewer_frame(viewer_id, data)}], state}
  end

  # Control-plane JSON from the Session (peer_join / peer_left).
  def handle_info({:onlytty_control, json}, state) do
    {:push, [{:text, json}], state}
  end

  # A peer arrived; relay binary to it from now on.
  def handle_info({:add_peer, pid}, state) do
    {:ok, %{state | peers: MapSet.put(state.peers, pid)}}
  end

  def handle_info({:add_peer, pid, viewer_id}, state) do
    {:ok,
     %{
       state
       | peers: MapSet.put(state.peers, pid),
         viewer_peers: Map.put(state.viewer_peers, viewer_id, pid),
         peer_ids: Map.put(state.peer_ids, pid, viewer_id)
     }}
  end

  # A peer left; stop relaying binary to it.
  def handle_info({:del_peer, pid}, state) do
    viewer_id = Map.get(state.peer_ids, pid)

    state = %{
      state
      | peers: MapSet.delete(state.peers, pid),
        peer_ids: Map.delete(state.peer_ids, pid),
        viewer_peers:
          if(viewer_id, do: Map.delete(state.viewer_peers, viewer_id), else: state.viewer_peers)
    }

    {:ok, state}
  end

  # The Session is closing us (TTL / idle): send {"t":"bye",reason} then close.
  def handle_info({:close, code, reason}, state) do
    {:stop, :normal, {code, reason}, [{:text, bye(reason)}], state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  # Bandit rejects an oversize frame at the parser (before handle_in, so it is never
  # forwarded to the peer) and terminates us with this reason. Count it so operators
  # can see frame-cap hits; the close code on the wire is 1009 (message too big).
  def terminate({:error, :max_frame_size_exceeded}, state) do
    OnlyTTY.Metrics.inc(:frame_size_rejects)

    Logger.info(
      "relay session #{String.slice(state.id, 0, 8)}: #{state.role} frame over cap — closed"
    )

    :ok
  end

  def terminate(_reason, state) do
    # Log only a short id prefix — the full id is the viewer connect capability.
    Logger.info("relay session #{String.slice(state.id, 0, 8)}: #{state.role} socket closed")
    :ok
  end

  # --- control-plane JSON (metadata only, never terminal content) ------------

  defp base_state(session, id, role) do
    %{
      session: session,
      id: id,
      role: role,
      peers: MapSet.new(),
      viewer_peers: %{},
      peer_ids: %{},
      viewer_id: nil,
      # Read once at connect so the hot path is a bare integer compare, no app-env lookup.
      max_queue: max_viewer_queue()
    }
  end

  defp max_viewer_queue do
    Application.get_env(:onlytty, :max_viewer_queue, @default_max_viewer_queue)
  end

  # True when runner frames are backing up in our mailbox faster than we can push them
  # to the client — the stalled-viewer signal. `message_queue_len` counts the frames
  # still queued behind the one we're handling now.
  defp slow_viewer?(state) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, len} -> len > state.max_queue
      _ -> false
    end
  end

  defp evict_slow_viewer(state) do
    OnlyTTY.Metrics.inc(:viewer_slow_evicted)
    # Log only a short id prefix — the full id is the viewer connect capability.
    Logger.info("relay session #{String.slice(state.id, 0, 8)}: viewer too slow — evicted")
    {:stop, :normal, {@close_slow, "too_slow"}, state}
  end

  defp hello(role, snap) do
    %{
      t: "hello",
      role: Atom.to_string(role),
      viewers: snap.viewers,
      locked: snap.locked,
      expires_at: snap.expires_at
    }
    |> maybe_put(:viewer_id, Map.get(snap, :viewer_id))
    |> Jason.encode!()
  end

  defp control(:peer_join, viewer_id, viewers) do
    Jason.encode!(%{t: "peer_join", viewer_id: viewer_id, viewers: viewers})
  end

  defp control(:busy), do: Jason.encode!(%{t: "busy"})

  defp bye(reason), do: Jason.encode!(%{t: "bye", reason: reason})

  defp send_to_viewer(%{"viewer_id" => viewer_id, "frame" => frame64}, state)
       when is_binary(viewer_id) and is_binary(frame64) do
    with pid when is_pid(pid) <- Map.get(state.viewer_peers, viewer_id),
         {:ok, frame} <- Base.decode64(frame64) do
      send(pid, {:onlytty_binary, frame})
    end
  end

  defp send_to_viewer(_msg, _state), do: :ok

  defp relay_viewer_frame(viewer_id, data) when is_binary(viewer_id) do
    <<@relay_viewer_magic::binary, byte_size(viewer_id), viewer_id::binary, data::binary>>
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp decode_control(data) do
    case Jason.decode(data) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end
end
