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

  # The runner generates its own id + runner token (URL-safe, >= 120 bits).
  defp tok, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  describe "POST /api/sessions" do
    test "registers the runner-supplied id+token; no expiry by default", %{conn: conn} do
      id = tok()
      token = tok()
      conn = post(conn, ~p"/api/sessions", %{id: id, runner_token: token})
      assert conn.status == 201
      body = json_response(conn, 201)

      assert body["id"] == id
      assert body["runner_token"] == token
      # No --ttl → no expiry → expires_at is the 0 sentinel.
      assert body["expires_at"] == 0
    end

    test "honors a custom ttl_seconds", %{conn: conn} do
      now = System.system_time(:second)
      conn = post(conn, ~p"/api/sessions", %{id: tok(), runner_token: tok(), ttl_seconds: 120})
      body = json_response(conn, 201)
      assert body["expires_at"] > now + 110
      assert body["expires_at"] <= now + 120 + 5
    end

    test "honors a large ttl_seconds when no ceiling is configured", %{conn: conn} do
      now = System.system_time(:second)

      conn =
        post(conn, ~p"/api/sessions", %{id: tok(), runner_token: tok(), ttl_seconds: 999_999_999})

      body = json_response(conn, 201)
      # ONLYTTY_MAX_TTL is unset in test, so there is no ceiling — the TTL is honored.
      assert body["expires_at"] > now + 999_999_999 - 5
    end

    test "clamps an absurd ttl_seconds to the hard ceiling instead of crashing", %{conn: conn} do
      # A multi-millennium ttl would overflow the BEAM timer (ArgumentError in
      # Process.send_after) and 500; it must be clamped to the ~100-year hard max.
      now = System.system_time(:second)

      conn =
        post(conn, ~p"/api/sessions", %{
          id: tok(),
          runner_token: tok(),
          ttl_seconds: 1_000_000_000_000_000
        })

      body = json_response(conn, 201)
      assert body["expires_at"] > now
      assert body["expires_at"] <= now + 3_153_600_000 + 5
    end

    test "clamps a too-small ttl_seconds up to the 60s min", %{conn: conn} do
      now = System.system_time(:second)
      conn = post(conn, ~p"/api/sessions", %{id: tok(), runner_token: tok(), ttl_seconds: 1})
      body = json_response(conn, 201)
      assert body["expires_at"] >= now + 60 - 1
    end

    test "rejects a non-integer ttl_seconds with 400 and creates no session", %{conn: conn} do
      conn = post(conn, ~p"/api/sessions", %{id: tok(), runner_token: tok(), ttl_seconds: "abc"})
      body = json_response(conn, 400)
      assert body["error"] =~ "ttl_seconds"
      refute Map.has_key?(body, "id")
    end

    test "requires both id and runner_token", %{conn: conn} do
      assert json_response(post(conn, ~p"/api/sessions", %{}), 400)["error"] =~ "id"

      assert json_response(post(conn, ~p"/api/sessions", %{id: tok()}), 400)["error"] =~
               "runner_token"

      # A too-short / non-URL-safe id is rejected as invalid.
      bad = post(conn, ~p"/api/sessions", %{id: "short", runner_token: tok()})
      assert json_response(bad, 400)["error"] =~ "id"
    end

    test "re-posting the same id+token attaches (idempotent), keeping the expiry", %{conn: conn} do
      id = tok()
      token = tok()
      first = post(conn, ~p"/api/sessions", %{id: id, runner_token: token, ttl_seconds: 120})
      first_body = json_response(first, 201)
      assert first_body["id"] == id

      again = post(conn, ~p"/api/sessions", %{id: id, runner_token: token})
      body = json_response(again, 201)
      assert body["id"] == id
      # Attaching keeps the original session's expiry; it does not reset the TTL.
      assert body["expires_at"] == first_body["expires_at"]
    end

    test "the same id with a wrong token is rejected 401", %{conn: conn} do
      id = tok()
      assert post(conn, ~p"/api/sessions", %{id: id, runner_token: tok()}).status == 201

      conn = post(conn, ~p"/api/sessions", %{id: id, runner_token: tok()})
      assert json_response(conn, 401)["error"] =~ "another runner"
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
