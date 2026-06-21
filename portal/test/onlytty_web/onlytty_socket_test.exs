defmodule OnlyttyWeb.OnlyttySocketTest do
  @moduledoc """
  End-to-end WebSocket behavior, driven by a real gun client against the running
  Bandit endpoint. Covers auth, the binary relay, the control plane, the
  single-viewer lock, and the TTL close path.
  """
  use ExUnit.Case, async: false

  alias Onlytty.{SessionStore, WSClient}

  setup do
    port = Application.get_env(:onlytty, OnlyttyWeb.Endpoint)[:http][:port]
    %{port: port}
  end

  defp new_session(opts \\ []) do
    {:ok, s} = SessionStore.create(opts)
    s
  end

  defp runner_headers(token), do: [{"authorization", "Bearer " <> token}]

  describe "auth" do
    test "runner with a valid token connects", %{port: port} do
      s = new_session()
      pid = WSClient.open(port)

      assert {:ok, ref} =
               WSClient.upgrade(pid, "/ws/runner/#{s.id}", runner_headers(s.runner_token))

      hello = WSClient.recv_json(pid, ref)
      assert hello["t"] == "hello" and hello["role"] == "runner"
      WSClient.close(pid)
    end

    test "runner with a wrong token is rejected (401)", %{port: port} do
      s = new_session()
      pid = WSClient.open(port)
      assert {:error, 401} = WSClient.upgrade(pid, "/ws/runner/#{s.id}", runner_headers("nope"))
      WSClient.close(pid)
    end

    test "runner with no Authorization header is rejected (401)", %{port: port} do
      s = new_session()
      pid = WSClient.open(port)
      assert {:error, 401} = WSClient.upgrade(pid, "/ws/runner/#{s.id}", [])
      WSClient.close(pid)
    end

    test "ws to an unknown session id is rejected (404)", %{port: port} do
      pid = WSClient.open(port)
      assert {:error, 404} = WSClient.upgrade(pid, "/ws/viewer/nonexistent-id", [])

      assert {:error, 404} =
               WSClient.upgrade(pid, "/ws/runner/nonexistent-id", runner_headers("x"))

      WSClient.close(pid)
    end

    test "viewer connects by id alone", %{port: port} do
      s = new_session()
      pid = WSClient.open(port)
      assert {:ok, ref} = WSClient.upgrade(pid, "/ws/viewer/#{s.id}", [])
      hello = WSClient.recv_json(pid, ref)
      assert hello["t"] == "hello" and hello["role"] == "viewer"
      WSClient.close(pid)
    end
  end

  describe "binary relay (the core)" do
    test "binary frames are delivered byte-identical in both directions", %{port: port} do
      s = new_session()

      runner = WSClient.open(port)
      r_ref = WSClient.connect!(runner, "/ws/runner/#{s.id}", runner_headers(s.runner_token))
      assert WSClient.recv_json(runner, r_ref)["t"] == "hello"

      viewer = WSClient.open(port)
      v_ref = WSClient.connect!(viewer, "/ws/viewer/#{s.id}", [])
      assert WSClient.recv_json(viewer, v_ref)["t"] == "hello"
      # viewer sees runner present
      assert WSClient.recv_json(viewer, v_ref)["t"] == "peer_join"
      # runner sees the viewer join
      assert WSClient.recv_json(runner, r_ref)["t"] == "peer_join"

      # runner -> viewer, including non-utf8 bytes (opaque ciphertext)
      payload = <<0, 1, 2, 255, 254, "encrypted-ish", 0>>
      WSClient.send_binary(runner, r_ref, payload)
      assert WSClient.recv_binary(viewer, v_ref) == payload

      # viewer -> runner
      back = :crypto.strong_rand_bytes(64)
      WSClient.send_binary(viewer, v_ref, back)
      assert WSClient.recv_binary(runner, r_ref) == back

      WSClient.close(runner)
      WSClient.close(viewer)
    end

    test "binary from the runner with no viewer present is dropped, not buffered", %{port: port} do
      s = new_session()
      runner = WSClient.open(port)
      r_ref = WSClient.connect!(runner, "/ws/runner/#{s.id}", runner_headers(s.runner_token))
      assert WSClient.recv_json(runner, r_ref)["t"] == "hello"

      # No viewer yet: relay must not echo or error.
      WSClient.send_binary(runner, r_ref, <<1, 2, 3>>)
      WSClient.refute_frame(runner, r_ref)

      WSClient.close(runner)
    end
  end

  describe "control plane" do
    test "runner gets peer_join on viewer connect and peer_left on disconnect", %{port: port} do
      s = new_session()
      runner = WSClient.open(port)
      r_ref = WSClient.connect!(runner, "/ws/runner/#{s.id}", runner_headers(s.runner_token))
      assert WSClient.recv_json(runner, r_ref)["t"] == "hello"

      viewer = WSClient.open(port)
      v_ref = WSClient.connect!(viewer, "/ws/viewer/#{s.id}", [])
      assert WSClient.recv_json(viewer, v_ref)["t"] == "hello"

      assert WSClient.recv_json(runner, r_ref)["t"] == "peer_join"

      # Viewer leaves -> runner is told peer_left.
      WSClient.close(viewer)
      assert WSClient.recv_json(runner, r_ref)["t"] == "peer_left"

      WSClient.close(runner)
    end

    test "viewer is told peer_left when the runner disconnects", %{port: port} do
      s = new_session()
      runner = WSClient.open(port)
      r_ref = WSClient.connect!(runner, "/ws/runner/#{s.id}", runner_headers(s.runner_token))
      assert WSClient.recv_json(runner, r_ref)["t"] == "hello"

      viewer = WSClient.open(port)
      v_ref = WSClient.connect!(viewer, "/ws/viewer/#{s.id}", [])
      assert WSClient.recv_json(viewer, v_ref)["t"] == "hello"
      assert WSClient.recv_json(viewer, v_ref)["t"] == "peer_join"
      assert WSClient.recv_json(runner, r_ref)["t"] == "peer_join"

      WSClient.close(runner)
      assert WSClient.recv_json(viewer, v_ref)["t"] == "peer_left"

      WSClient.close(viewer)
    end

    test "client {\"t\":\"bye\"} closes that socket", %{port: port} do
      s = new_session()
      pid = WSClient.open(port)
      ref = WSClient.connect!(pid, "/ws/viewer/#{s.id}", [])
      assert WSClient.recv_json(pid, ref)["t"] == "hello"

      WSClient.send_text(pid, ref, Jason.encode!(%{t: "bye"}))
      assert {1000, _} = WSClient.recv_close(pid, ref)
      WSClient.close(pid)
    end

    test "runner {\"t\":\"bye\",\"reason\":\"ended\"} closes the whole session", %{port: port} do
      s = new_session()

      runner = WSClient.open(port)
      r_ref = WSClient.connect!(runner, "/ws/runner/#{s.id}", runner_headers(s.runner_token))
      assert WSClient.recv_json(runner, r_ref)["t"] == "hello"

      viewer = WSClient.open(port)
      v_ref = WSClient.connect!(viewer, "/ws/viewer/#{s.id}", [])
      assert WSClient.recv_json(viewer, v_ref)["t"] == "hello"
      assert WSClient.recv_json(viewer, v_ref)["t"] == "peer_join"
      assert WSClient.recv_json(runner, r_ref)["t"] == "peer_join"

      WSClient.send_text(runner, r_ref, Jason.encode!(%{t: "bye", reason: "ended"}))

      bye = WSClient.recv_json(viewer, v_ref)
      assert bye["t"] == "bye" and bye["reason"] == "ended"
      assert {4000, "ended"} = WSClient.recv_close(viewer, v_ref)
      assert {4000, "ended"} = WSClient.recv_close(runner, r_ref)

      WSClient.close(runner)
      WSClient.close(viewer)
    end
  end

  describe "single-viewer lock" do
    test "a second viewer gets busy and is closed; the first stays", %{port: port} do
      s = new_session()

      v1 = WSClient.open(port)
      v1_ref = WSClient.connect!(v1, "/ws/viewer/#{s.id}", [])
      assert WSClient.recv_json(v1, v1_ref)["t"] == "hello"

      v2 = WSClient.open(port)
      v2_ref = WSClient.connect!(v2, "/ws/viewer/#{s.id}", [])
      assert WSClient.recv_json(v2, v2_ref)["t"] == "busy"
      assert {4002, _} = WSClient.recv_close(v2, v2_ref)

      # The first viewer is unaffected: a runner can still reach it.
      runner = WSClient.open(port)
      r_ref = WSClient.connect!(runner, "/ws/runner/#{s.id}", runner_headers(s.runner_token))
      assert WSClient.recv_json(runner, r_ref)["t"] == "hello"
      # v1 learns the runner arrived, then relays binary.
      assert WSClient.recv_json(v1, v1_ref)["t"] == "peer_join"

      WSClient.send_binary(runner, r_ref, <<9, 9, 9>>)
      assert WSClient.recv_binary(v1, v1_ref) == <<9, 9, 9>>

      WSClient.close(v1)
      WSClient.close(runner)
    end
  end

  describe "frame-size cap" do
    # Bandit logs the oversize close at :error level; capture it so the suite stays quiet.
    @describetag :capture_log

    test "an oversize frame is rejected (1009) and never reaches the peer", %{port: port} do
      s = new_session()

      runner = WSClient.open(port)
      r_ref = WSClient.connect!(runner, "/ws/runner/#{s.id}", runner_headers(s.runner_token))
      assert WSClient.recv_json(runner, r_ref)["t"] == "hello"

      viewer = WSClient.open(port)
      v_ref = WSClient.connect!(viewer, "/ws/viewer/#{s.id}", [])
      assert WSClient.recv_json(viewer, v_ref)["t"] == "hello"
      assert WSClient.recv_json(viewer, v_ref)["t"] == "peer_join"
      assert WSClient.recv_json(runner, r_ref)["t"] == "peer_join"

      # A normal-size frame relays through fine.
      WSClient.send_binary(runner, r_ref, <<1, 2, 3>>)
      assert WSClient.recv_binary(viewer, v_ref) == <<1, 2, 3>>

      before = Onlytty.Metrics.value(:frame_size_rejects)

      # Just over the 1 MiB default cap: Bandit closes the sender with 1009 before the
      # payload is ever forwarded, so the viewer only learns the runner dropped.
      WSClient.send_binary(runner, r_ref, :binary.copy(<<0>>, 1024 * 1024 + 1))
      assert {1009, _} = WSClient.recv_close(runner, r_ref)
      assert WSClient.recv_json(viewer, v_ref)["t"] == "peer_left"
      WSClient.refute_frame(viewer, v_ref)
      assert Onlytty.Metrics.value(:frame_size_rejects) == before + 1

      WSClient.close(viewer)
    end

    test "the cap is runtime-configurable", %{port: port} do
      # Lower the cap; the upgrade reads it, so connect AFTER setting it.
      Application.put_env(:onlytty, :max_frame_bytes, 1024)
      on_exit(fn -> Application.delete_env(:onlytty, :max_frame_bytes) end)

      s = new_session()
      runner = WSClient.open(port)
      r_ref = WSClient.connect!(runner, "/ws/runner/#{s.id}", runner_headers(s.runner_token))
      assert WSClient.recv_json(runner, r_ref)["t"] == "hello"

      # 2 KiB > the 1 KiB cap → rejected; a small frame would have passed.
      WSClient.send_binary(runner, r_ref, :binary.copy(<<0>>, 2048))
      assert {1009, _} = WSClient.recv_close(runner, r_ref)
    end
  end

  describe "ttl" do
    test "a session past its ttl closes the sockets with reason expired", %{port: port} do
      # Min ttl is clamped to 60s, so drive expiry directly via the session pid
      # rather than sleeping. This exercises the real :ttl_expired path.
      s = new_session()
      {:ok, session_pid} = SessionStore.lookup(s.id)

      runner = WSClient.open(port)
      r_ref = WSClient.connect!(runner, "/ws/runner/#{s.id}", runner_headers(s.runner_token))
      assert WSClient.recv_json(runner, r_ref)["t"] == "hello"

      send(session_pid, :ttl_expired)

      bye = WSClient.recv_json(runner, r_ref)
      assert bye["t"] == "bye" and bye["reason"] == "expired"
      assert {4000, _} = WSClient.recv_close(runner, r_ref)

      WSClient.close(runner)
    end

    test "idle timeout closes the runner with reason idle", %{port: port} do
      s = new_session()
      {:ok, session_pid} = SessionStore.lookup(s.id)

      runner = WSClient.open(port)
      r_ref = WSClient.connect!(runner, "/ws/runner/#{s.id}", runner_headers(s.runner_token))
      assert WSClient.recv_json(runner, r_ref)["t"] == "hello"

      send(session_pid, :idle_expired)

      bye = WSClient.recv_json(runner, r_ref)
      assert bye["t"] == "bye" and bye["reason"] == "idle"
      assert {4000, _} = WSClient.recv_close(runner, r_ref)

      WSClient.close(runner)
    end
  end
end
