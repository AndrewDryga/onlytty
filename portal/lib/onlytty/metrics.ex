defmodule OnlyTTY.Metrics do
  @moduledoc """
  Low-cardinality operator counters, exposed at `GET /metrics` in Prometheus text
  exposition format. Backed by an OTP `:counters` array — lock-free and cheap to
  bump from any process on the hot path.

  Every counter is a fixed, label-free aggregate: there is deliberately *no*
  session id, IP, or other per-session label, so the endpoint reveals only totals
  and never anything about an individual session. Keep it that way — adding a
  high-cardinality label (or anything derived from a session id / URL) would both
  blow up Prometheus and leak. The `/metrics` endpoint must still be firewalled or
  kept behind the proxy, not exposed publicly (see README).

  The counter array is allocated once at application boot (`setup/0`) and its
  reference stashed in `:persistent_term`, so `inc/1` is a single atomic add with
  no message pass.
  """

  # name -> help text. The order here is the exposition order. The exposed metric
  # name is `onlytty_<name>_total`. Add to this list to introduce a counter; the
  # index is its position, assigned at compile time below.
  @counters [
    {:sessions_created, "Sessions successfully created."},
    {:sessions_at_capacity,
     "Session-create requests refused because the relay was at the concurrent-session cap."},
    {:runners_connected, "Runner WebSocket connections accepted (includes reconnects)."},
    {:viewers_connected, "Viewer WebSocket connections accepted."},
    {:viewer_busy_rejects,
     "Viewer connections refused because the single-viewer lock was already held."},
    {:upgrade_unauthorized, "WebSocket upgrades rejected 401 (bad or missing runner token)."},
    {:upgrade_not_found, "WebSocket upgrades rejected 404 (unknown or expired session)."},
    {:sessions_ttl_expired,
     "Sessions closed by TTL expiry (includes reaping a session whose runner never connected)."},
    {:sessions_idle_expired, "Sessions closed by the idle timeout."},
    {:rate_limit_rejects, "Session-create requests refused by the per-IP rate limiter."},
    # Counted in OnlyTTYSocket.terminate/2 when Bandit closes a socket (1009) for an
    # over-cap frame (ONLYTTY_MAX_FRAME_BYTES).
    {:frame_size_rejects, "Frames rejected for exceeding the maximum frame size."}
  ]

  @size length(@counters)
  @index @counters |> Enum.with_index(1) |> Map.new(fn {{name, _help}, i} -> {name, i} end)
  @pt_key __MODULE__

  @doc """
  Allocate the counter array and stash it in `:persistent_term`. Idempotent, so a
  release boot or a test app restart reuses the existing array instead of zeroing
  it. Call once from the supervision tree's `start/2`, before the endpoint.
  """
  @spec setup() :: :ok
  def setup do
    unless :persistent_term.get(@pt_key, nil) do
      :persistent_term.put(@pt_key, :counters.new(@size, [:write_concurrency]))
    end

    :ok
  end

  @doc "Increment a counter by one. Unknown names raise (a typo is a bug, not a no-op)."
  @spec inc(atom()) :: :ok
  def inc(name) do
    :counters.add(ref(), Map.fetch!(@index, name), 1)
    :ok
  end

  @doc "Current value of a counter. For tests and introspection."
  @spec value(atom()) :: non_neg_integer()
  def value(name), do: :counters.get(ref(), Map.fetch!(@index, name))

  @doc "Render all counters as Prometheus text exposition (one HELP/TYPE/value block each)."
  @spec render() :: binary()
  def render do
    r = ref()

    @counters
    |> Enum.with_index(1)
    |> Enum.map(fn {{name, help}, idx} ->
      metric = "onlytty_#{name}_total"

      [
        "# HELP ",
        metric,
        " ",
        help,
        "\n# TYPE ",
        metric,
        " counter\n",
        metric,
        " ",
        Integer.to_string(:counters.get(r, idx)),
        "\n"
      ]
    end)
    |> IO.iodata_to_binary()
  end

  defp ref do
    :persistent_term.get(@pt_key, nil) ||
      raise "OnlyTTY.Metrics not set up; call OnlyTTY.Metrics.setup/0 at application start"
  end
end
