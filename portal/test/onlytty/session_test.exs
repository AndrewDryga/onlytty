defmodule OnlyTTY.SessionTest do
  @moduledoc """
  Lifecycle tests for `OnlyTTY.Session`: the unconnected reap (which bounds how long an
  empty session can hold a process and the single-session/lock budget), and the viewer
  set — locked admits one viewer, unlocked holds several without overwriting or leaking a
  monitor, and each viewer is wired to / unwired from the runner independently.
  """
  use ExUnit.Case, async: true

  alias OnlyTTY.Session

  # Start a Session directly with a tiny unconnected-reap window and a long TTL, so a
  # reap can only be the unconnected path (never the TTL). Returns the session pid.
  # Extra opts (e.g. `locked: false`) are merged in.
  defp start_session(unconnected_ms, opts \\ []) do
    id = "test-" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

    base = [
      id: id,
      runner_token: "tok",
      ttl_seconds: 3600,
      idle_ms: 600_000,
      unconnected_ms: unconnected_ms
    ]

    start_supervised!({Session, Keyword.merge(base, opts)})
  end

  # Join as a viewer from a fresh process (join_viewer registers self() as a viewer), so
  # killing it drives the session's viewer :DOWN handler. Returns the viewer pid.
  defp spawn_viewer(session) do
    parent = self()

    viewer =
      spawn(fn ->
        reply = Session.join_viewer(session)
        send(parent, {:joined, self(), reply})
        Process.sleep(:infinity)
      end)

    assert_receive {:joined, ^viewer, reply}, 1_000
    {viewer, reply}
  end

  # Join as the runner from a fresh process (join_runner registers self() as the
  # runner), so killing that process drives the session's runner :DOWN handler.
  defp spawn_runner(session) do
    parent = self()

    runner =
      spawn(fn ->
        {:ok, _snap} = Session.join_runner(session)
        send(parent, :joined)
        Process.sleep(:infinity)
      end)

    assert_receive :joined, 1_000
    runner
  end

  test "a runner that drops and never reconnects is reaped after the grace window" do
    session = start_session(120)
    ref = Process.monitor(session)

    runner = spawn_runner(session)
    Process.exit(runner, :kill)

    # The re-armed unconnected reap closes the empty session well before TTL.
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 1_000
  end

  test "a runner that reconnects within the window cancels the reap" do
    session = start_session(300)
    ref = Process.monitor(session)

    runner = spawn_runner(session)
    Process.exit(runner, :kill)
    # Reconnect promptly — within the 300ms grace.
    _runner2 = spawn_runner(session)

    # The reap was cancelled by the reconnect: the session is still alive after the
    # window would have elapsed.
    refute_receive {:DOWN, ^ref, :process, ^session, _}, 600
    assert Process.alive?(session)
  end

  describe "viewer set" do
    test "locked (the default) admits one viewer and rejects a second as busy" do
      session = start_session(60_000)

      assert {_v1, {:ok, snap}} = spawn_viewer(session)
      assert snap.viewers == 1
      assert snap.locked

      # A second viewer, joining from this process, is turned away.
      assert :busy == Session.join_viewer(session)
    end

    test "unlocked holds several viewers, wiring each to the runner independently" do
      session = start_session(60_000, locked: false)

      # This process is the runner, so it receives the peer-wiring messages the session
      # hands out. join_runner cancels the unconnected reap, keeping the session alive.
      assert {:ok, %{viewers: 0}} = Session.join_runner(session)

      {v1, {:ok, %{viewers: 1, locked: false, viewer_id: v1_id}}} = spawn_viewer(session)
      # The runner is wired to v1 and told a peer joined.
      assert_receive {:add_peer, ^v1, ^v1_id}
      assert_receive {:onlytty_control, join1}

      assert %{"t" => "peer_join", "viewer_id" => ^v1_id, "viewers" => 1} =
               Jason.decode!(join1)

      {v2, {:ok, %{viewers: 2, viewer_id: v2_id}}} = spawn_viewer(session)
      assert_receive {:add_peer, ^v2, ^v2_id}
      assert_receive {:onlytty_control, join2}

      assert %{"t" => "peer_join", "viewer_id" => ^v2_id, "viewers" => 2} =
               Jason.decode!(join2)

      # v1 leaves: the runner drops only v1 and learns which viewer left, but the
      # viewers count says v2 is still attached.
      Process.exit(v1, :kill)
      assert_receive {:del_peer, ^v1}
      refute_receive {:del_peer, ^v2}, 200
      assert_receive {:onlytty_control, left1}

      assert %{"t" => "peer_left", "viewer_id" => ^v1_id, "viewers" => 1} =
               Jason.decode!(left1)

      # v2 (the last viewer) leaves: now the runner is told peer_left.
      Process.exit(v2, :kill)
      assert_receive {:del_peer, ^v2}
      assert_receive {:onlytty_control, left}

      assert %{"t" => "peer_left", "viewer_id" => ^v2_id, "viewers" => 0} =
               Jason.decode!(left)
    end
  end
end
