defmodule OnlyttyWeb.OnlyttySocket do
  @moduledoc """
  The `WebSock` handler shared by both ends of a relay. One instance runs per
  connected socket (it *is* the Bandit connection process). Runner and viewer
  behave almost identically here — they differ only in role and in which side's
  traffic resets the idle timer — so a single handler takes a `:role`.

  The contract (PROTOCOL.md):

    * **binary** frames are end-to-end ciphertext. We forward them verbatim to
      the peer process and never parse, log, or store them. If there is no peer,
      we drop (the runner buffers; that is the runner's job).
    * **text** frames are the control plane (JSON, metadata only). On connect we
      send `{"t":"hello",...}`. A viewer `{"t":"bye"}` closes that socket; a
      runner `{"t":"bye","reason":"ended"}` closes the whole session.

  Auth and session existence are checked in `OnlyttyWeb.SocketController` *before*
  the upgrade, so by the time `init/1` runs the session is known to exist and
  (for runners) the token has matched. `init/1` only does the join, which can
  still return `:busy` for a second viewer under the single-viewer lock.

  State: `%{session, id, role, peer}` — `peer` is the peer socket pid or nil.
  """

  @behaviour WebSock

  require Logger

  alias Onlytty.Session

  @close_normal 1000
  @close_busy 4002

  @impl true
  def init(%{session: session, id: id, role: :runner}) do
    {:ok, snap} = Session.join_runner(session)
    state = %{session: session, id: id, role: :runner, peer: nil}
    {:push, [{:text, hello(:runner, snap)}], state}
  end

  def init(%{session: session, id: id, role: :viewer}) do
    case Session.join_viewer(session) do
      {:ok, snap} ->
        state = %{session: session, id: id, role: :viewer, peer: nil}
        frames = [{:text, hello(:viewer, snap)}]
        # If the runner is already here, tell the viewer its peer is present.
        frames =
          if snap.runner_present, do: frames ++ [{:text, control(:peer_join)}], else: frames

        {:push, frames, state}

      :busy ->
        # Single-viewer lock held: report busy, then close. The runner and the
        # existing viewer are untouched.
        {:stop, :normal, {@close_busy, "busy"}, [{:text, control(:busy)}],
         %{session: session, id: id, role: :viewer, peer: nil}}
    end
  end

  @impl true
  # Binary = opaque E2E payload: forward verbatim to the peer, never inspect it.
  def handle_in({data, opcode: :binary}, state) do
    if state.role == :runner, do: Session.runner_active(state.session)
    if is_pid(state.peer), do: send(state.peer, {:onlytty_binary, data})
    {:ok, state}
  end

  # Text = control plane. Viewer bye closes just that socket; runner bye is the
  # command-exit signal and closes the whole session so viewers see a final state.
  def handle_in({data, opcode: :text}, state) do
    case decode_control(data) do
      {:ok, %{"t" => "bye"} = msg} when state.role == :runner ->
        Session.close(state.session, Map.get(msg, "reason", "closed"))
        {:ok, state}

      {:ok, %{"t" => "bye"}} ->
        {:stop, :normal, {@close_normal, "closed"}, state}

      _ ->
        {:ok, state}
    end
  end

  @impl true
  # Peer-to-peer binary relay: push the bytes straight out to our client.
  def handle_info({:onlytty_binary, data}, state) do
    {:push, [{:binary, data}], state}
  end

  # Control-plane JSON from the Session (peer_join / peer_left).
  def handle_info({:onlytty_control, json}, state) do
    {:push, [{:text, json}], state}
  end

  # Our peer arrived; relay binary directly to it from now on.
  def handle_info({:set_peer, pid}, state) do
    {:ok, %{state | peer: pid}}
  end

  # Our peer left; drop binary until a new peer arrives.
  def handle_info(:peer_left, state) do
    {:ok, %{state | peer: nil}}
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
    Onlytty.Metrics.inc(:frame_size_rejects)

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

  defp hello(role, snap) do
    Jason.encode!(%{
      t: "hello",
      role: Atom.to_string(role),
      viewers: snap.viewers,
      locked: snap.locked,
      expires_at: snap.expires_at
    })
  end

  defp control(:peer_join), do: Jason.encode!(%{t: "peer_join"})
  defp control(:busy), do: Jason.encode!(%{t: "busy"})

  defp bye(reason), do: Jason.encode!(%{t: "bye", reason: reason})

  defp decode_control(data) do
    case Jason.decode(data) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end
end
