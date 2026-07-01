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
end
