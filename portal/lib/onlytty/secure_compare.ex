defmodule OnlyTTY.SecureCompare do
  @moduledoc """
  Constant-time equality for secrets (tokens, bearer credentials) so a wrong
  value can't be recovered by timing the comparison. The single home for this in
  the relay — route every secret compare through here rather than hand-rolling it.

  Delegates to `Plug.Crypto.secure_compare/2` (a transitive dep via Phoenix/Plug),
  which is constant-time and tolerates unequal-length inputs without raising. The
  guard keeps a nil/garbage input from crashing an auth path — it returns false.
  """

  @doc """
  Returns true only when `a` and `b` are equal binaries, in constant time.
  Non-binary input, or a length/content mismatch, returns false without raising.
  """
  @spec equal?(term(), term()) :: boolean()
  def equal?(a, b) when is_binary(a) and is_binary(b), do: Plug.Crypto.secure_compare(a, b)
  def equal?(_, _), do: false
end
