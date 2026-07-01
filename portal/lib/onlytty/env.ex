defmodule Onlytty.Env do
  @moduledoc """
  Tiny parsers for operational environment variables, used by `config/runtime.exs`.

  The point is fail-fast validation: a bad operational value should raise a clear,
  named error at boot rather than corrupting behavior or crashing at request time.
  The acute case is `ONLYTTY_RATELIMIT_WINDOW=0`, which would otherwise reach
  `Onlytty.RateLimit` as a window of `0` and raise `ArithmeticError` on the first
  `div(now, window)` — a runtime crash, not a boot failure.
  """

  @doc """
  Parse `value` as a positive integer, or raise `ArgumentError` naming the variable.

  Rejects zero, negatives, and anything non-numeric (including trailing junk like
  `"1.5"` or `"10x"`).
  """
  @spec pos_int!(String.t(), String.t()) :: pos_integer()
  def pos_int!(name, value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 ->
        n

      _ ->
        raise ArgumentError, "#{name} must be a positive integer, got: #{inspect(value)}"
    end
  end

  @doc """
  Parse `value` as a non-negative integer (0 allowed), or raise `ArgumentError` naming
  the variable. Used where 0 is a meaningful "off"/"none" setting, such as
  `ONLYTTY_TRUSTED_PROXY_HOPS=0` (no reverse proxy).
  """
  @spec non_neg_int!(String.t(), String.t()) :: non_neg_integer()
  def non_neg_int!(name, value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 ->
        n

      _ ->
        raise ArgumentError, "#{name} must be a non-negative integer, got: #{inspect(value)}"
    end
  end
end
