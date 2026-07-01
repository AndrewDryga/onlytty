defmodule OnlyttyWeb.RateLimitTest do
  @moduledoc "Per-IP throttling of POST /api/sessions."
  # async: false — these toggle the global rate-limit config.
  use OnlyttyWeb.ConnCase, async: false

  alias Onlytty.RateLimit

  setup do
    prev_max = Application.get_env(:onlytty, :rate_limit_max)
    prev_win = Application.get_env(:onlytty, :rate_limit_window_ms)
    prev_hops = Application.get_env(:onlytty, :trusted_proxy_hops)

    on_exit(fn ->
      Application.put_env(:onlytty, :rate_limit_max, prev_max)
      Application.put_env(:onlytty, :rate_limit_window_ms, prev_win)

      case prev_hops do
        nil -> Application.delete_env(:onlytty, :trusted_proxy_hops)
        v -> Application.put_env(:onlytty, :trusted_proxy_hops, v)
      end
    end)

    :ok
  end

  test "allows up to the limit, then throttles with a positive retry-after" do
    Application.put_env(:onlytty, :rate_limit_max, 2)
    Application.put_env(:onlytty, :rate_limit_window_ms, 60_000)
    key = {:unit, System.unique_integer()}

    assert RateLimit.check(key) == :ok
    assert RateLimit.check(key) == :ok
    assert {:error, retry} = RateLimit.check(key)
    assert retry > 0
  end

  test "resets after the window elapses" do
    Application.put_env(:onlytty, :rate_limit_max, 1)
    Application.put_env(:onlytty, :rate_limit_window_ms, 50)
    key = {:reset, System.unique_integer()}

    assert RateLimit.check(key) == :ok
    assert {:error, _} = RateLimit.check(key)
    Process.sleep(80)
    assert RateLimit.check(key) == :ok
  end

  test "POST /api/sessions returns 429 + Retry-After and creates no session when throttled",
       %{conn: conn} do
    Application.put_env(:onlytty, :rate_limit_max, 1)
    Application.put_env(:onlytty, :rate_limit_window_ms, 60_000)
    ip = {198, 51, 100, 7}

    ok = %{conn | remote_ip: ip} |> post(~p"/api/sessions", %{id: tok(), runner_token: tok()})
    assert json_response(ok, 201)["id"]

    throttled = %{conn | remote_ip: ip} |> post(~p"/api/sessions")
    body = json_response(throttled, 429)
    refute Map.has_key?(body, "id")
    assert [retry] = get_resp_header(throttled, "retry-after")
    assert String.to_integer(retry) > 0
  end

  test "throttles before Plug.Parsers — an over-limit request with a malformed body is 429, not 400",
       %{conn: conn} do
    Application.put_env(:onlytty, :rate_limit_max, 1)
    Application.put_env(:onlytty, :rate_limit_window_ms, 60_000)
    ip = {198, 51, 100, 8}

    # Spend the single allowed request.
    ok = %{conn | remote_ip: ip} |> post(~p"/api/sessions", %{id: tok(), runner_token: tok()})
    assert json_response(ok, 201)["id"]

    # A malformed JSON body would make Plug.Parsers raise (→ 400) if it ran first.
    # Getting a clean 429 proves the throttle halts the conn before any parsing.
    throttled =
      %{conn | remote_ip: ip}
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/sessions", "{not valid json")

    assert json_response(throttled, 429)["error"] =~ "rate limited"
  end

  test "behind a trusted proxy (hops=1), clients sharing the LB peer get separate buckets",
       %{conn: conn} do
    Application.put_env(:onlytty, :rate_limit_max, 1)
    Application.put_env(:onlytty, :rate_limit_window_ms, 60_000)
    Application.put_env(:onlytty, :trusted_proxy_hops, 1)

    lb = {130, 211, 0, 1}
    xff = fn client -> "#{client}, 130.211.0.1" end

    create = fn client ->
      %{conn | remote_ip: lb}
      |> put_req_header("x-forwarded-for", xff.(client))
      |> post(~p"/api/sessions", %{id: tok(), runner_token: tok()})
    end

    # Client A spends its one allowed request.
    assert json_response(create.("203.0.113.9"), 201)["id"]

    # Client B shares the LB peer but is a different real client → its own bucket → allowed.
    assert json_response(create.("203.0.113.10"), 201)["id"]

    # Client A again → throttled: the key is the XFF client, not the shared LB peer.
    throttled =
      %{conn | remote_ip: lb}
      |> put_req_header("x-forwarded-for", xff.("203.0.113.9"))
      |> post(~p"/api/sessions")

    assert json_response(throttled, 429)["error"] =~ "rate limited"
  end

  test "with no trusted proxy, a spoofed X-Forwarded-For cannot multiply the bucket",
       %{conn: conn} do
    Application.put_env(:onlytty, :rate_limit_max, 1)
    Application.put_env(:onlytty, :rate_limit_window_ms, 60_000)
    Application.delete_env(:onlytty, :trusted_proxy_hops)
    peer = {203, 0, 113, 20}

    first =
      %{conn | remote_ip: peer}
      |> put_req_header("x-forwarded-for", "1.1.1.1")
      |> post(~p"/api/sessions", %{id: tok(), runner_token: tok()})

    assert json_response(first, 201)["id"]

    # Same peer, a DIFFERENT spoofed XFF: without a trusted proxy it's ignored, so this
    # still hits the same (peer) bucket → throttled. A client can't split its own bucket.
    second =
      %{conn | remote_ip: peer}
      |> put_req_header("x-forwarded-for", "2.2.2.2")
      |> post(~p"/api/sessions")

    assert json_response(second, 429)["error"] =~ "rate limited"
  end

  defp tok, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
