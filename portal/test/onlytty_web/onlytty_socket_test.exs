defmodule OnlyttyWeb.OnlyttySocketTest do
  @moduledoc """
  End-to-end WebSocket behavior, driven by a real gun client against the running
  Bandit endpoint. Covers auth, the binary relay, the control plane, the
  single-viewer lock, and the TTL close path.
  """
  use ExUnit.Case, async: false

  alias Onlytty.{SessionStore, WSClient}
  import Onlytty.Test.RuntimeEnv, only: [with_runtime_env: 2]

  setup do
    port = Application.get_env(:onlytty, OnlyttyWeb.Endpoint)[:http][:port]
    %{port: port}
  end

  defp new_session(opts \\ []) do
    {:ok, s} = SessionStore.create_or_attach(token(), token(), opts)
    s
  end

  defp token, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

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

  describe "viewer Origin check (defense-in-depth)" do
    test "a foreign Origin is rejected (403)", %{port: port} do
      s = new_session()
      pid = WSClient.open(port)

      assert {:error, 403} =
               WSClient.upgrade(pid, "/ws/viewer/#{s.id}", [{"origin", "https://evil.example"}])

      WSClient.close(pid)
    end

    test "the same-origin Origin connects (host matches the request)", %{port: port} do
      s = new_session()
      pid = WSClient.open(port)
      # WSClient connects to 127.0.0.1, so a same-host Origin is allowed by default.
      assert {:ok, ref} =
               WSClient.upgrade(pid, "/ws/viewer/#{s.id}", [
                 {"origin", "http://127.0.0.1:#{port}"}
               ])

      assert WSClient.recv_json(pid, ref)["t"] == "hello"
      WSClient.close(pid)
    end

    test "a missing Origin (non-browser) still connects", %{port: port} do
      s = new_session()
      pid = WSClient.open(port)
      assert {:ok, ref} = WSClient.upgrade(pid, "/ws/viewer/#{s.id}", [])
      assert WSClient.recv_json(pid, ref)["t"] == "hello"
      WSClient.close(pid)
    end

    test "the allowlist is additive to same-host; runner WS is never gated", %{port: port} do
      with_runtime_env(%{"ONLYTTY_ALLOWED_ORIGINS" => "https://allowed.example"}, fn ->
        s = new_session()

        # The configured origin is allowed for the viewer…
        v = WSClient.open(port)

        assert {:ok, vref} =
                 WSClient.upgrade(v, "/ws/viewer/#{s.id}", [
                   {"origin", "https://allowed.example"}
                 ])

        assert WSClient.recv_json(v, vref)["t"] == "hello"
        WSClient.close(v)

        # …and the same-host viewer STILL connects (the allowlist is a union, not a
        # replacement) — setting ONLYTTY_ALLOWED_ORIGINS must not lock out same-host.
        same = WSClient.open(port)

        assert {:ok, sref} =
                 WSClient.upgrade(same, "/ws/viewer/#{s.id}", [
                   {"origin", "http://127.0.0.1:#{port}"}
                 ])

        assert WSClient.recv_json(same, sref)["t"] == "hello"
        WSClient.close(same)

        # …while a foreign, unlisted Origin is still rejected.
        bad = WSClient.open(port)

        assert {:error, 403} =
                 WSClient.upgrade(bad, "/ws/viewer/#{s.id}", [{"origin", "https://evil.example"}])

        WSClient.close(bad)

        # …but the runner (non-browser) connects regardless of a foreign Origin.
        r = WSClient.open(port)

        assert {:ok, rref} =
                 WSClient.upgrade(r, "/ws/runner/#{s.id}", [
                   {"authorization", "Bearer " <> s.runner_token},
                   {"origin", "https://evil.example"}
                 ])

        assert WSClient.recv_json(r, rref)["t"] == "hello"
        WSClient.close(r)
      end)
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

    test "a reconnecting runner displaces and closes the old runner socket", %{port: port} do
      s = new_session()

      r1 = WSClient.open(port)
      r1_ref = WSClient.connect!(r1, "/ws/runner/#{s.id}", runner_headers(s.runner_token))
      assert WSClient.recv_json(r1, r1_ref)["t"] == "hello"

      viewer = WSClient.open(port)
      v_ref = WSClient.connect!(viewer, "/ws/viewer/#{s.id}", [])
      assert WSClient.recv_json(viewer, v_ref)["t"] == "hello"
      assert WSClient.recv_json(viewer, v_ref)["t"] == "peer_join"
      assert WSClient.recv_json(r1, r1_ref)["t"] == "peer_join"

      # runner2 reconnects with the same id/token → it displaces runner1.
      r2 = WSClient.open(port)
      r2_ref = WSClient.connect!(r2, "/ws/runner/#{s.id}", runner_headers(s.runner_token))
      assert WSClient.recv_json(r2, r2_ref)["t"] == "hello"

      # The displaced runner1 socket is closed by the relay (4000 bye, or a hard down).
      assert WSClient.recv_close_or_down(r1, r1_ref) in [4000, :down]

      # The viewer is re-told its peer is present (the new runner), then runner2 ↔ viewer
      # relays normally — proving the new socket, not the zombie, owns the channel.
      assert WSClient.recv_json(viewer, v_ref)["t"] == "peer_join"
      payload = <<7, 8, 9, 10>>
      WSClient.send_binary(r2, r2_ref, payload)
      assert WSClient.recv_binary(viewer, v_ref) == payload

      WSClient.close(r2)
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

  describe "multiple viewers (unlocked)" do
    test "runner output broadcasts to every viewer, and each viewer's input reaches the runner",
         %{port: port} do
      s = new_session(locked: false)

      runner = WSClient.open(port)
      r_ref = WSClient.connect!(runner, "/ws/runner/#{s.id}", runner_headers(s.runner_token))
      assert WSClient.recv_json(runner, r_ref)["t"] == "hello"

      v1 = WSClient.open(port)
      v1_ref = WSClient.connect!(v1, "/ws/viewer/#{s.id}", [])
      assert WSClient.recv_json(v1, v1_ref)["t"] == "hello"
      assert WSClient.recv_json(v1, v1_ref)["t"] == "peer_join"
      assert WSClient.recv_json(runner, r_ref)["t"] == "peer_join"

      # A second viewer attaches to the SAME unlocked session (no busy).
      v2 = WSClient.open(port)
      v2_ref = WSClient.connect!(v2, "/ws/viewer/#{s.id}", [])
      assert WSClient.recv_json(v2, v2_ref)["t"] == "hello"
      assert WSClient.recv_json(v2, v2_ref)["t"] == "peer_join"
      assert WSClient.recv_json(runner, r_ref)["t"] == "peer_join"

      # Runner output reaches BOTH viewers byte-identically.
      payload = <<0, 1, 2, 255, "broadcast", 0>>
      WSClient.send_binary(runner, r_ref, payload)
      assert WSClient.recv_binary(v1, v1_ref) == payload
      assert WSClient.recv_binary(v2, v2_ref) == payload

      # Each viewer's input reaches the runner (arbitration is a runner/E2E concern).
      WSClient.send_binary(v1, v1_ref, <<1, 1, 1>>)
      assert WSClient.recv_binary(runner, r_ref) == <<1, 1, 1>>
      WSClient.send_binary(v2, v2_ref, <<2, 2, 2>>)
      assert WSClient.recv_binary(runner, r_ref) == <<2, 2, 2>>

      WSClient.close(runner)
      WSClient.close(v1)
      WSClient.close(v2)
    end

    test "one viewer leaving removes only it; the rest keep receiving; last leaving → peer_left",
         %{port: port} do
      s = new_session(locked: false)

      runner = WSClient.open(port)
      r_ref = WSClient.connect!(runner, "/ws/runner/#{s.id}", runner_headers(s.runner_token))
      assert WSClient.recv_json(runner, r_ref)["t"] == "hello"

      v1 = WSClient.open(port)
      v1_ref = WSClient.connect!(v1, "/ws/viewer/#{s.id}", [])
      assert WSClient.recv_json(v1, v1_ref)["t"] == "hello"
      assert WSClient.recv_json(v1, v1_ref)["t"] == "peer_join"
      assert WSClient.recv_json(runner, r_ref)["t"] == "peer_join"

      v2 = WSClient.open(port)
      v2_ref = WSClient.connect!(v2, "/ws/viewer/#{s.id}", [])
      assert WSClient.recv_json(v2, v2_ref)["t"] == "hello"
      assert WSClient.recv_json(v2, v2_ref)["t"] == "peer_join"
      assert WSClient.recv_json(runner, r_ref)["t"] == "peer_join"

      # v1 leaves. The runner is NOT told peer_left — v2 is still attached — so it must
      # keep streaming to v2.
      WSClient.close(v1)
      WSClient.refute_frame(runner, r_ref)

      WSClient.send_binary(runner, r_ref, <<7, 7, 7>>)
      assert WSClient.recv_binary(v2, v2_ref) == <<7, 7, 7>>

      # v2 (the last viewer) leaves: now the runner learns its channel is empty.
      WSClient.close(v2)
      assert WSClient.recv_json(runner, r_ref)["t"] == "peer_left"

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

      # Just over the 1 MiB default cap: Bandit rejects the frame and closes the sender —
      # a 1009 close frame, or an abrupt drop under load — before the payload is ever
      # forwarded, so the viewer only learns the runner dropped. The metric below confirms
      # the reject regardless of how the close surfaced.
      WSClient.send_binary(runner, r_ref, :binary.copy(<<0>>, 1024 * 1024 + 1))
      assert WSClient.recv_close_or_down(runner, r_ref) in [1009, :down]
      assert WSClient.recv_json(viewer, v_ref)["t"] == "peer_left"
      WSClient.refute_frame(viewer, v_ref)
      assert Onlytty.Metrics.value(:frame_size_rejects) == before + 1

      WSClient.close(viewer)
    end

    test "the cap is runtime-configurable", %{port: port} do
      with_runtime_env(%{"ONLYTTY_MAX_FRAME_BYTES" => "1024"}, fn ->
        s = new_session()
        runner = WSClient.open(port)
        r_ref = WSClient.connect!(runner, "/ws/runner/#{s.id}", runner_headers(s.runner_token))
        assert WSClient.recv_json(runner, r_ref)["t"] == "hello"

        # 2 KiB > the 1 KiB cap → rejected; a small frame would have passed. The reject
        # surfaces as a 1009 close frame, or an abrupt drop under load.
        WSClient.send_binary(runner, r_ref, :binary.copy(<<0>>, 2048))
        assert WSClient.recv_close_or_down(runner, r_ref) in [1009, :down]
      end)
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
