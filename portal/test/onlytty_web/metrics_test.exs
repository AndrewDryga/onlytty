defmodule OnlyttyWeb.MetricsTest do
  @moduledoc """
  `GET /metrics` exposes aggregate operator counters in Prometheus text format.

  Counters are process-global (an OTP `:counters` array), so these tests assert on
  the *delta* across an action rather than an absolute value — other tests bump the
  same counters. `async: false` keeps each delta attributable to its own action.
  """
  use OnlyttyWeb.ConnCase, async: false

  alias Onlytty.{Metrics, SessionStore, WSClient}

  defp delta(name, fun) do
    before = Metrics.value(name)
    fun.()
    Metrics.value(name) - before
  end

  test "GET /metrics returns 200 Prometheus text", %{conn: conn} do
    conn = get(conn, ~p"/metrics")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"

    body = conn.resp_body
    # Every declared counter is present with a HELP/TYPE/value triple.
    assert body =~ "# TYPE onlytty_sessions_created_total counter"
    assert body =~ ~r/^onlytty_sessions_created_total \d+$/m
    assert body =~ "onlytty_frame_size_rejects_total"
  end

  test "creating a session increments onlytty_sessions_created_total", %{conn: conn} do
    assert delta(:sessions_created, fn ->
             assert post(conn, ~p"/api/sessions").status == 201
           end) == 1
  end

  test "a viewer upgrade for an unknown id increments the 404 counter" do
    port = Application.get_env(:onlytty, OnlyttyWeb.Endpoint)[:http][:port]

    assert delta(:upgrade_not_found, fn ->
             pid = WSClient.open(port)
             assert {:error, 404} = WSClient.upgrade(pid, "/ws/viewer/nonexistent-id", [])
             WSClient.close(pid)
           end) == 1
  end

  test "a second viewer under the single-viewer lock increments the busy counter" do
    port = Application.get_env(:onlytty, OnlyttyWeb.Endpoint)[:http][:port]
    {:ok, s} = SessionStore.create([])

    assert delta(:viewer_busy_rejects, fn ->
             v1 = WSClient.open(port)
             v1_ref = WSClient.connect!(v1, "/ws/viewer/#{s.id}", [])
             assert WSClient.recv_json(v1, v1_ref)["t"] == "hello"

             v2 = WSClient.open(port)
             v2_ref = WSClient.connect!(v2, "/ws/viewer/#{s.id}", [])
             assert WSClient.recv_json(v2, v2_ref)["t"] == "busy"

             WSClient.close(v1)
             WSClient.close(v2)
           end) == 1
  end

  test "the exposition contains no session id", %{conn: conn} do
    # Create a session, then prove its id never appears in the aggregate output.
    {:ok, s} = SessionStore.create([])
    body = get(conn, ~p"/metrics").resp_body
    refute body =~ s.id
  end
end
