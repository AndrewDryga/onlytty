defmodule Onlytty.Test.RuntimeEnv do
  @moduledoc false

  @env_names [
    "ONLYTTY_DEFAULT_TTL",
    "ONLYTTY_MAX_TTL",
    "ONLYTTY_IDLE_TIMEOUT",
    "ONLYTTY_MAX_SESSIONS",
    "ONLYTTY_MAX_FRAME_BYTES",
    "ONLYTTY_ALLOWED_ORIGINS",
    "ONLYTTY_RATELIMIT_MAX",
    "ONLYTTY_RATELIMIT_WINDOW",
    "ONLYTTY_TRUSTED_PROXY_HOPS",
    "ONLYTTY_METRICS_TOKEN"
  ]

  @app_keys [
    :default_ttl,
    :max_ttl,
    :idle_timeout_ms,
    :max_sessions,
    :max_frame_bytes,
    :allowed_origins,
    :rate_limit_max,
    :rate_limit_window_ms,
    :trusted_proxy_hops,
    :metrics_token
  ]

  def with_runtime_env(vars, fun) when is_map(vars) and is_function(fun, 0) do
    prev_env = Map.new(@env_names, &{&1, System.get_env(&1)})
    prev_app = Map.new(@app_keys, &{&1, Application.fetch_env(:onlytty, &1)})

    try do
      Enum.each(@env_names, &System.delete_env/1)
      Enum.each(vars, fn {key, value} -> System.put_env(key, to_string(value)) end)
      restore_app(prev_app)

      for {key, value} <- Onlytty.Env.runtime_overrides() do
        Application.put_env(:onlytty, key, value)
      end

      fun.()
    after
      restore_env(prev_env)
      restore_app(prev_app)
    end
  end

  defp restore_env(prev_env) do
    Enum.each(prev_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app(prev_app) do
    Enum.each(prev_app, fn
      {key, {:ok, value}} -> Application.put_env(:onlytty, key, value)
      {key, :error} -> Application.delete_env(:onlytty, key)
    end)
  end
end
