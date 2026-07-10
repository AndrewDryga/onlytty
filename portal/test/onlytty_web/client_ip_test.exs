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

  test "edge: keys on the LAST X-Forwarded-For entry (a single trusted edge proxy)" do
    with_runtime_env(%{"ONLYTTY_TRUSTED_PROXY_HOPS" => "edge"}, fn ->
      # A lone reverse proxy (Caddy/nginx) appends the real client as the last entry;
      # the direct peer is the proxy.
      assert ClientIP.resolve(conn({10, 0, 0, 1}, "203.0.113.9")) == {203, 0, 113, 9}
    end)
  end

  test "edge: a spoofed leading XFF entry cannot move the read position" do
    with_runtime_env(%{"ONLYTTY_TRUSTED_PROXY_HOPS" => "edge"}, fn ->
      # The client prepends 1.2.3.4; the proxy still appends (or overwrites to) the real
      # client as the LAST entry, so reading the last position lands on the real client.
      assert ClientIP.resolve(conn({10, 0, 0, 1}, "1.2.3.4, 203.0.113.9")) == {203, 0, 113, 9}
    end)
  end

  test "edge: two different clients get two different keys" do
    with_runtime_env(%{"ONLYTTY_TRUSTED_PROXY_HOPS" => "edge"}, fn ->
      proxy = {10, 0, 0, 1}
      a = ClientIP.resolve(conn(proxy, "203.0.113.9"))
      b = ClientIP.resolve(conn(proxy, "198.51.100.7"))

      refute a == b
      assert a == {203, 0, 113, 9}
      assert b == {198, 51, 100, 7}
    end)
  end

  test "edge: absent or malformed X-Forwarded-For falls back to the peer" do
    with_runtime_env(%{"ONLYTTY_TRUSTED_PROXY_HOPS" => "edge"}, fn ->
      peer = {10, 0, 0, 1}

      assert ClientIP.resolve(conn(peer, nil)) == peer
      assert ClientIP.resolve(conn(peer, "")) == peer
      assert ClientIP.resolve(conn(peer, "garbage")) == peer
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

  test "IPv6: a bracketed client literal is parsed and masked to its /64" do
    with_runtime_env(%{"ONLYTTY_TRUSTED_PROXY_HOPS" => "1"}, fn ->
      peer = {0, 0, 0, 0, 0, 0xFFFF, 0x8213, 1}

      # The full /128 (…::1) collapses to its /64 (groups 5–8 zeroed).
      assert ClientIP.resolve(conn(peer, "[2001:db8::1], 2001:db8::2")) ==
               {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}
    end)
  end

  test "IPv6: two addresses in the same /64 collapse to one key" do
    with_runtime_env(%{"ONLYTTY_TRUSTED_PROXY_HOPS" => "0"}, fn ->
      a = ClientIP.resolve(conn({0x2001, 0x0DB8, 1, 2, 0, 0, 0, 0x1111}, nil))
      b = ClientIP.resolve(conn({0x2001, 0x0DB8, 1, 2, 0xFFFF, 0xFFFF, 0xFFFF, 0x2222}, nil))

      assert a == b
      assert a == {0x2001, 0x0DB8, 1, 2, 0, 0, 0, 0}
    end)
  end

  test "IPv6: addresses in different /64s stay distinct" do
    with_runtime_env(%{"ONLYTTY_TRUSTED_PROXY_HOPS" => "0"}, fn ->
      a = ClientIP.resolve(conn({0x2001, 0x0DB8, 1, 2, 0, 0, 0, 1}, nil))
      b = ClientIP.resolve(conn({0x2001, 0x0DB8, 1, 3, 0, 0, 0, 1}, nil))

      refute a == b
    end)
  end

  test "IPv4 keys are unchanged by masking (full /32)" do
    with_runtime_env(%{"ONLYTTY_TRUSTED_PROXY_HOPS" => "0"}, fn ->
      assert ClientIP.resolve(conn({198, 51, 100, 7}, nil)) == {198, 51, 100, 7}
    end)
  end
end
