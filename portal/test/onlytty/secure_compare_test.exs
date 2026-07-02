defmodule OnlyTTY.SecureCompareTest do
  @moduledoc "The single constant-time secret compare used by every auth path in the relay."
  use ExUnit.Case, async: true

  alias OnlyTTY.SecureCompare

  test "equal binaries compare true" do
    assert SecureCompare.equal?("s3cret-token", "s3cret-token")
    assert SecureCompare.equal?("", "")
  end

  test "unequal same-length binaries compare false" do
    refute SecureCompare.equal?("aaaa", "aaab")
  end

  test "unequal different-length binaries compare false without raising" do
    refute SecureCompare.equal?("short", "a-much-longer-token")
    refute SecureCompare.equal?("nonempty", "")
  end

  test "non-binary input compares false without raising" do
    refute SecureCompare.equal?(nil, "token")
    refute SecureCompare.equal?("token", nil)
    refute SecureCompare.equal?(nil, nil)
    refute SecureCompare.equal?(:token, "token")
  end
end
