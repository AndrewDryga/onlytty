defmodule OnlyttyWeb.RateLimitTest do
  @moduledoc "Per-IP throttling of POST /api/sessions."
  # async: false — these toggle the global rate-limit config.
  use OnlyttyWeb.ConnCase, async: false

  alias Onlytty.RateLimit

  setup do
    prev_max = Application.get_env(:onlytty, :rate_limit_max)
    prev_win = Application.get_env(:onlytty, :rate_limit_window_ms)

    on_exit(fn ->
      Application.put_env(:onlytty, :rate_limit_max, prev_max)
      Application.put_env(:onlytty, :rate_limit_window_ms, prev_win)
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

    ok = %{conn | remote_ip: ip} |> post(~p"/api/sessions")
    assert json_response(ok, 201)["id"]

    throttled = %{conn | remote_ip: ip} |> post(~p"/api/sessions")
    body = json_response(throttled, 429)
    refute Map.has_key?(body, "id")
    assert [retry] = get_resp_header(throttled, "retry-after")
    assert String.to_integer(retry) > 0
  end
end
