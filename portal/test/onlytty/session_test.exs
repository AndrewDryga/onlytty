defmodule Onlytty.SessionTest do
  @moduledoc """
  Lifecycle tests for `Onlytty.Session` — specifically the unconnected reap, which
  bounds how long an empty session (no runner attached) can hold a process and the
  single-session/lock budget. The reap window is passed in small so the test is fast.
  """
  use ExUnit.Case, async: true

  alias Onlytty.Session

  # Start a Session directly with a tiny unconnected-reap window and a long TTL, so a
  # reap can only be the unconnected path (never the TTL). Returns the session pid.
  defp start_session(unconnected_ms) do
    id = "test-" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

    pid =
      start_supervised!(
        {Session,
         id: id,
         runner_token: "tok",
         ttl_seconds: 3600,
         idle_ms: 600_000,
         unconnected_ms: unconnected_ms}
      )

    pid
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
end
