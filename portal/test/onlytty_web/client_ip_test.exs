defmodule OnlyTTYWeb.ClientIPTest do
  @moduledoc "Proxy-aware, spoof-resistant client-IP resolution for the rate-limit key."
  # async: false — toggles the global :trusted_proxy_hops app env.
  use ExUnit.Case, async: false

  alias OnlyTTYWeb.ClientIP
  import OnlyTTY.Test.RuntimeEnv, only: [with_runtime_env: 2]

  defp conn(remote_ip, xff) do
    headers = if xff, do: [{"x-forwarded-for", xff}], else: []
    %Plug.Conn{remote_ip: remote_ip, req_headers: headers}
  end

  test "no proxy (default): keys on the direct peer and ignores X-Forwarded-For" do
    with_runtime_env(%{"ONLYTTY_TRUSTED_PROXY_HOPS" => "0"}, fn ->
      # Even a spoofed loopback/private XFF is ignored when no hops are configured.
      assert ClientIP.resolve(conn({198, 51, 100, 7}, "127.0.0.1, 10.0.0.1")) ==
               {198, 51, 100, 7}
    end)
  end

  test "hops=0 behaves like no proxy" do
    with_runtime_env(%{"ONLYTTY_TRUSTED_PROXY_HOPS" => "0"}, fn ->
      assert ClientIP.resolve(conn({198, 51, 100, 7}, "203.0.113.9")) == {198, 51, 100, 7}
    end)
  end

  test "hops=1 (Google HTTPS LB shape): the client is the second-to-last XFF entry" do
    with_runtime_env(%{"ONLYTTY_TRUSTED_PROXY_HOPS" => "1"}, fn ->
      # XFF is `<client>, <GFE>`; the direct peer is the LB.
      assert ClientIP.resolve(conn({130, 211, 0, 1}, "203.0.113.9, 130.211.0.1")) ==
               {203, 0, 113, 9}
    end)
  end

  test "hops=1: a spoofed leading XFF entry cannot move the read position" do
    with_runtime_env(%{"ONLYTTY_TRUSTED_PROXY_HOPS" => "1"}, fn ->
      # The attacker prepends 1.2.3.4; the LB still appends the real client + its own IP,
      # so the fixed offset from the right lands on the real client, not the spoof.
      assert ClientIP.resolve(conn({130, 211, 0, 1}, "1.2.3.4, 203.0.113.9, 130.211.0.1")) ==
               {203, 0, 113, 9}
    end)
  end

  test "hops=2: a chain of two trusted proxies" do
    with_runtime_env(%{"ONLYTTY_TRUSTED_PROXY_HOPS" => "2"}, fn ->
      assert ClientIP.resolve(conn({10, 0, 0, 1}, "203.0.113.9, 172.16.0.1, 10.0.0.1")) ==
               {203, 0, 113, 9}
    end)
  end

  test "short or malformed X-Forwarded-For falls back to the peer" do
    with_runtime_env(%{"ONLYTTY_TRUSTED_PROXY_HOPS" => "1"}, fn ->
      peer = {130, 211, 0, 1}

      # Fewer entries than the hop count needs → offset is negative → fall back.
      assert ClientIP.resolve(conn(peer, "130.211.0.1")) == peer
      # No X-Forwarded-For at all.
      assert ClientIP.resolve(conn(peer, nil)) == peer
      # The client slot isn't a valid IP → fall back rather than key on junk.
      assert ClientIP.resolve(conn(peer, "garbage, 130.211.0.1")) == peer
    end)
  end

  test "IPv6: a bracketed client literal is parsed" do
    with_runtime_env(%{"ONLYTTY_TRUSTED_PROXY_HOPS" => "1"}, fn ->
      peer = {0, 0, 0, 0, 0, 0xFFFF, 0x8213, 1}

      assert ClientIP.resolve(conn(peer, "[2001:db8::1], 2001:db8::2")) ==
               {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
    end)
  end
end
