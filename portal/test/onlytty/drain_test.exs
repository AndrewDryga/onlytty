defmodule OnlyTTY.DrainTest do
  # async: false — flips the global drain flag (persistent_term), which /healthz reads.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias OnlyTTY.{Drain, Session, SessionStore}

  setup do
    Drain.clear_draining()
    on_exit(&Drain.clear_draining/0)
    :ok
  end

  defp tok, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  test "draining? defaults to false and flips with the flag" do
    refute Drain.draining?()
    Drain.mark_draining()
    assert Drain.draining?()
  end

  test "/healthz returns 200 normally and 503 while draining" do
    assert OnlyTTYWeb.SessionController.healthz(build_conn(), %{}).status == 200
    Drain.mark_draining()
    assert OnlyTTYWeb.SessionController.healthz(build_conn(), %{}).status == 503
  end

  test "Session.drain nudges the connected sockets with a going_away frame" do
    {:ok, %{id: id}} = SessionStore.create_or_attach(tok(), tok(), [])
    {:ok, pid} = SessionStore.lookup(id)
    # Stand in as both the runner and the (single) viewer socket. The replace_state fun
    # runs IN the session process, so capture the test pid first (self() there is not
    # self() here). Viewers are a `%{pid => monitor_ref}` map; the ref is unused by drain.
    test_pid = self()

    :sys.replace_state(pid, fn s ->
      %{s | runner: test_pid, viewers: %{test_pid => make_ref()}}
    end)

    assert :ok = Session.drain(pid)

    # Two going_away frames: one for the runner, one for the viewer (both this process).
    assert_receive {:onlytty_control, j1}
    assert_receive {:onlytty_control, j2}
    assert Jason.decode!(j1)["t"] == "going_away"
    assert Jason.decode!(j2)["t"] == "going_away"
  end

  test "notify_local_sessions does not crash when called" do
    assert :ok = Drain.notify_local_sessions()
  end
end
