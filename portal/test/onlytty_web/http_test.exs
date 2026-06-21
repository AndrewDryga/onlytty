defmodule OnlyttyWeb.HTTPTest do
  @moduledoc "Plain HTTP endpoints: session creation, health, viewer page."
  use OnlyttyWeb.ConnCase, async: true

  # The directives that prove the policy is strict where it matters — scripts are
  # same-origin only (style-src keeps 'unsafe-inline' for xterm; see SecurityHeaders).
  # Matched loosely so adding directives later doesn't break the test.
  @csp_required ["default-src 'none'", "script-src 'self'", "frame-ancestors 'none'"]

  defp assert_security_headers(conn) do
    assert [csp] = get_resp_header(conn, "content-security-policy")
    for part <- @csp_required, do: assert(csp =~ part)
    # The load-bearing property: scripts are same-origin only, never inline/eval.
    refute csp =~ "unsafe-eval"
    refute csp =~ "script-src 'self' 'unsafe-inline'"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert [_ | _] = get_resp_header(conn, "permissions-policy")
    conn
  end

  describe "POST /api/sessions" do
    test "returns id, runner_token and a future expires_at", %{conn: conn} do
      conn = post(conn, ~p"/api/sessions")
      assert conn.status == 201
      body = json_response(conn, 201)

      assert is_binary(body["id"]) and byte_size(body["id"]) >= 16
      assert is_binary(body["runner_token"]) and byte_size(body["runner_token"]) >= 16
      assert body["id"] != body["runner_token"]

      # default ttl is 1800s; expires_at must be ~30 min in the future.
      now = System.system_time(:second)
      assert body["expires_at"] > now + 1700
      assert body["expires_at"] <= now + 1800 + 5
    end

    test "honors a custom ttl_seconds", %{conn: conn} do
      now = System.system_time(:second)
      conn = post(conn, ~p"/api/sessions", %{ttl_seconds: 120})
      body = json_response(conn, 201)
      assert body["expires_at"] > now + 110
      assert body["expires_at"] <= now + 120 + 5
    end

    test "clamps a too-large ttl_seconds to the 7-day max", %{conn: conn} do
      now = System.system_time(:second)
      conn = post(conn, ~p"/api/sessions", %{ttl_seconds: 999_999_999})
      body = json_response(conn, 201)
      assert body["expires_at"] <= now + 604_800 + 5
      assert body["expires_at"] > now + 604_800 - 5
    end

    test "clamps a too-small ttl_seconds up to the 60s min", %{conn: conn} do
      now = System.system_time(:second)
      conn = post(conn, ~p"/api/sessions", %{ttl_seconds: 1})
      body = json_response(conn, 201)
      assert body["expires_at"] >= now + 60 - 1
    end

    test "rejects a non-integer ttl_seconds with 400 and creates no session", %{conn: conn} do
      conn = post(conn, ~p"/api/sessions", %{ttl_seconds: "abc"})
      body = json_response(conn, 400)
      assert body["error"] =~ "ttl_seconds"
      refute Map.has_key?(body, "id")
    end
  end

  test "GET /api/sessions returns 405 (POST only)", %{conn: conn} do
    conn = get(conn, ~p"/api/sessions")
    body = json_response(conn, 405)
    assert body["error"] =~ "POST"
    assert get_resp_header(conn, "allow") == ["POST"]
  end

  test "GET /healthz returns 200 ok", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert text_response(conn, 200) == "ok"
  end

  test "GET /install.sh serves the installer (the hero one-liner resolves)", %{conn: conn} do
    conn = get(conn, "/install.sh")
    assert conn.status == 200
    assert conn.resp_body =~ "#!/bin/sh"

    # Guard against drift: the served copy must match the canonical repo-root
    # install.sh (the Docker image ships ./portal, so we keep a copy under priv).
    canonical = Path.expand("../../../install.sh", __DIR__)
    assert conn.resp_body == File.read!(canonical)
  end

  test "GET /s/:id serves the viewer HTML even for an unknown id", %{conn: conn} do
    conn = get(conn, ~p"/s/does-not-exist")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
    assert conn.resp_body =~ "<title>OnlyTTY</title>"
  end

  describe "static asset cache policy" do
    test "first-party viewer JS is no-store (always re-fetch the audited bytes)", %{conn: conn} do
      for path <- ~w(/assets/app.js /assets/wire.js /assets/crypto.js /assets/keys.js) do
        c = get(conn, path)
        assert c.status == 200
        assert get_resp_header(c, "cache-control") == ["no-store"]
      end
    end

    test "the viewer page itself is no-store", %{conn: conn} do
      c = get(conn, ~p"/s/abc")
      assert get_resp_header(c, "cache-control") == ["no-store"]
    end

    test "vendored (SRI-pinned) assets are immutable", %{conn: conn} do
      c = get(conn, "/assets/vendor/xterm.1f991ac3.js")
      assert c.status == 200
      assert [cc] = get_resp_header(c, "cache-control")
      assert cc =~ "immutable"
      assert cc =~ "max-age=31536000"
    end
  end

  describe "security headers" do
    test "on the viewer page (the code-delivery trust boundary)", %{conn: conn} do
      assert_security_headers(get(conn, ~p"/s/abc"))
    end

    test "on the health check", %{conn: conn} do
      assert_security_headers(get(conn, ~p"/healthz"))
    end

    test "on static assets (so a swapped script can't dodge the policy)", %{conn: conn} do
      conn = get(conn, "/assets/app.js")
      assert conn.status == 200
      assert_security_headers(conn)
    end
  end
end
