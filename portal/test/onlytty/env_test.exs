defmodule Onlytty.EnvTest do
  @moduledoc "Fail-fast parsing of operational env vars (used by config/runtime.exs)."
  use ExUnit.Case, async: true

  alias Onlytty.Env

  test "parses a positive integer" do
    assert Env.pos_int!("ONLYTTY_MAX_SESSIONS", "2000") == 2000
    assert Env.pos_int!("X", "1") == 1
  end

  test "raises a clear, named error on zero, negatives, and non-numeric values" do
    for bad <- ["0", "-1", "-100", "abc", "", " ", "1.5", "10x", "0x10"] do
      assert_raise ArgumentError, ~r/ONLYTTY_RATELIMIT_WINDOW must be a positive integer/, fn ->
        Env.pos_int!("ONLYTTY_RATELIMIT_WINDOW", bad)
      end
    end
  end

  test "non_neg_int! parses zero and positives" do
    assert Env.non_neg_int!("ONLYTTY_TRUSTED_PROXY_HOPS", "0") == 0
    assert Env.non_neg_int!("ONLYTTY_TRUSTED_PROXY_HOPS", "2") == 2
  end

  test "non_neg_int! raises a clear, named error on negatives and non-numeric values" do
    for bad <- ["-1", "abc", "", " ", "1.5", "2x"] do
      assert_raise ArgumentError,
                   ~r/ONLYTTY_TRUSTED_PROXY_HOPS must be a non-negative integer/,
                   fn -> Env.non_neg_int!("ONLYTTY_TRUSTED_PROXY_HOPS", bad) end
    end
  end

  test "runtime_overrides parses operational process env into app config" do
    env = %{
      "ONLYTTY_RATELIMIT_MAX" => "1",
      "ONLYTTY_RATELIMIT_WINDOW" => "60",
      "ONLYTTY_TRUSTED_PROXY_HOPS" => "1",
      "ONLYTTY_ALLOWED_ORIGINS" => "https://a.example,https://b.example",
      "ONLYTTY_METRICS_TOKEN" => "secret"
    }

    assert Env.runtime_overrides(&Map.get(env, &1)) == [
             allowed_origins: ["https://a.example", "https://b.example"],
             rate_limit_max: 1,
             rate_limit_window_ms: 60_000,
             trusted_proxy_hops: 1,
             metrics_token: "secret"
           ]
  end

  test "runtime_overrides preserves the rate-limit disable sentinel" do
    assert Env.runtime_overrides(&Map.get(%{"ONLYTTY_RATELIMIT_MAX" => "0"}, &1)) == [
             rate_limit_max: :infinity
           ]
  end
end
