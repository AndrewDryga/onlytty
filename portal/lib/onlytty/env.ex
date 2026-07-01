defmodule OnlyTTY.Env do
  @moduledoc """
  Tiny parsers for operational environment variables, used by `config/runtime.exs`.

  The point is fail-fast validation: a bad operational value should raise a clear,
  named error at boot rather than corrupting behavior or crashing at request time.
  The acute case is `ONLYTTY_RATELIMIT_WINDOW=0`, which would otherwise reach
  `OnlyTTY.RateLimit` as a window of `0` and raise `ArithmeticError` on the first
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

  @doc """
  Runtime application config derived from operational environment variables.

  `config/runtime.exs` applies these at boot. Tests can also use this function after
  setting process env overrides, which keeps them on the same parsing/validation path
  operators use instead of mutating app env directly.
  """
  @spec runtime_overrides((String.t() -> String.t() | nil)) :: keyword()
  def runtime_overrides(get_env \\ &System.get_env/1) when is_function(get_env, 1) do
    []
    |> put_if_present(:default_ttl, get_env.("ONLYTTY_DEFAULT_TTL"), fn value ->
      pos_int!("ONLYTTY_DEFAULT_TTL", value)
    end)
    |> put_if_present(:max_ttl, get_env.("ONLYTTY_MAX_TTL"), fn value ->
      pos_int!("ONLYTTY_MAX_TTL", value)
    end)
    |> put_if_present(:idle_timeout_ms, get_env.("ONLYTTY_IDLE_TIMEOUT"), fn value ->
      pos_int!("ONLYTTY_IDLE_TIMEOUT", value) * 1000
    end)
    |> put_if_present(:max_sessions, get_env.("ONLYTTY_MAX_SESSIONS"), fn value ->
      pos_int!("ONLYTTY_MAX_SESSIONS", value)
    end)
    |> put_if_present(:max_frame_bytes, get_env.("ONLYTTY_MAX_FRAME_BYTES"), fn value ->
      pos_int!("ONLYTTY_MAX_FRAME_BYTES", value)
    end)
    |> put_if_present(:allowed_origins, get_env.("ONLYTTY_ALLOWED_ORIGINS"), fn value ->
      String.split(value, ",", trim: true)
    end)
    |> put_if_present(:rate_limit_max, get_env.("ONLYTTY_RATELIMIT_MAX"), fn
      "0" -> :infinity
      value -> pos_int!("ONLYTTY_RATELIMIT_MAX", value)
    end)
    |> put_if_present(:rate_limit_window_ms, get_env.("ONLYTTY_RATELIMIT_WINDOW"), fn value ->
      pos_int!("ONLYTTY_RATELIMIT_WINDOW", value) * 1000
    end)
    |> put_if_present(:trusted_proxy_hops, get_env.("ONLYTTY_TRUSTED_PROXY_HOPS"), fn value ->
      non_neg_int!("ONLYTTY_TRUSTED_PROXY_HOPS", value)
    end)
    |> put_if_present(:metrics_token, get_env.("ONLYTTY_METRICS_TOKEN"), & &1)
    |> Enum.reverse()
  end

  defp put_if_present(config, _key, nil, _parse), do: config

  defp put_if_present(config, key, value, parse) do
    [{key, parse.(value)} | config]
  end
end
