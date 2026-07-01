defmodule OnlyTTY.RateLimit do
  @moduledoc """
  A small in-memory, per-key fixed-window rate limiter for the unauthenticated
  `POST /api/sessions` path, so a client cannot fill the session pool and 503
  everyone else.

  It owns one ETS table and increments a per-`{key, window}` counter with the
  atomic `:ets.update_counter/4` (no GenServer call on the hot path). A periodic
  sweep drops expired windows so the table stays bounded. Windows are clock-aligned
  (`div(now, window_ms)`), so no per-key timestamp is stored.

  Tunable at runtime; set `:rate_limit_max` to `:infinity` to disable (the default
  in `:test`). See `ONLYTTY_RATELIMIT_MAX` / `ONLYTTY_RATELIMIT_WINDOW` in `runtime.exs`.
  """

  use GenServer

  @table :onlytty_rate_limit

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Records a request for `key` (typically the client IP) and reports whether it is
  within the limit. Returns `:ok`, or `{:error, retry_after_seconds}` when the
  window's quota is exhausted.
  """
  @spec check(term()) :: :ok | {:error, pos_integer()}
  def check(key) do
    case max_requests() do
      :infinity ->
        :ok

      max ->
        window = window_ms()
        now = System.system_time(:millisecond)
        bucket = div(now, window)
        count = :ets.update_counter(@table, {key, bucket}, {2, 1}, {{key, bucket}, 0})

        if count <= max do
          :ok
        else
          {:error, div((bucket + 1) * window - now, 1000) + 1}
        end
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    window = window_ms()
    current = div(System.system_time(:millisecond), window)
    # Drop every bucket older than the current window.
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", current}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, max(window_ms(), 1_000))

  defp max_requests, do: Application.get_env(:onlytty, :rate_limit_max, 30)
  defp window_ms, do: Application.get_env(:onlytty, :rate_limit_window_ms, 60_000)
end
