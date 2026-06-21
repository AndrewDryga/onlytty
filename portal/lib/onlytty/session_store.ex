defmodule Onlytty.SessionStore do
  @moduledoc """
  Creates sessions and looks them up by id. Sessions are in-memory only — a
  `Onlytty.Session` GenServer per session, started under a `DynamicSupervisor`
  and registered by id in `Onlytty.Registry`. Nothing is ever persisted.

  This is the boring lookup boundary the web layer talks to: controllers and
  socket handlers never touch the Registry or the supervisor directly.
  """

  alias Onlytty.Session

  @registry Onlytty.Registry
  @supervisor Onlytty.SessionSupervisor

  # TTL is opt-in. By default a session has NO expiry (0) and lives as long as the
  # runner runs — it ends when the command exits or the runner disconnects, not on a
  # clock. A positive `--ttl` opts into a time bound; a too-small one is floored at
  # @min_ttl so it can't expire before anyone connects. An operator of a shared relay
  # can impose a ceiling with ONLYTTY_MAX_TTL (a no-expiry request is then forced down
  # to it); unset means no ceiling. Both knobs are runtime app env (:default_ttl /
  # :max_ttl ← ONLYTTY_DEFAULT_TTL / ONLYTTY_MAX_TTL). 0 means "no expiry" throughout
  # (both `ttl_seconds` and `expires_at`).
  @default_ttl 0
  @min_ttl 60
  @max_ttl :infinity

  @doc "The Registry `:via` tuple used to name a session process by its id."
  def via(id), do: {:via, Registry, {@registry, id}}

  @doc """
  Create a new session. Generates a URL-safe id and a separate runner token
  (each >= 120 bits of entropy) and starts its GenServer.

  Returns `{:ok, %{id, runner_token, expires_at}}`.
  """
  @spec create(keyword()) ::
          {:ok, %{id: String.t(), runner_token: String.t(), expires_at: integer()}}
          | {:error, :at_capacity}
  def create(opts \\ []) do
    ttl = opts |> Keyword.get(:ttl_seconds) |> clamp_ttl()
    id = random_token()
    runner_token = random_token()

    child =
      {Session,
       id: id,
       runner_token: runner_token,
       ttl_seconds: ttl,
       idle_ms: idle_ms(),
       locked: Keyword.get(opts, :locked, true)}

    case DynamicSupervisor.start_child(@supervisor, child) do
      {:ok, _pid} ->
        Onlytty.Metrics.inc(:sessions_created)

        {:ok, %{id: id, runner_token: runner_token, expires_at: expiry_at(ttl)}}

      {:error, :max_children} ->
        # The cap is hit: refuse rather than grow unbounded.
        Onlytty.Metrics.inc(:sessions_at_capacity)
        {:error, :at_capacity}
    end
  end

  @doc "Look up a live session's pid by id."
  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(id) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  def lookup(_), do: :error

  @doc false
  def default_ttl, do: Application.get_env(:onlytty, :default_ttl, @default_ttl)

  @doc false
  def max_ttl, do: Application.get_env(:onlytty, :max_ttl, @max_ttl)

  # 16 random bytes = 128 bits, URL-safe, no padding.
  defp random_token, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # Returns the TTL in seconds, where 0 means "no expiry". An omitted request uses the
  # configured default; <= 0 means no expiry; a positive value is floored at @min_ttl.
  # cap/1 then applies the operator ceiling, forcing even a no-expiry request down to it
  # when ONLYTTY_MAX_TTL is set.
  defp clamp_ttl(nil), do: clamp_ttl(default_ttl())
  defp clamp_ttl(ttl) when is_integer(ttl) and ttl <= 0, do: cap(0)
  defp clamp_ttl(ttl) when is_integer(ttl), do: cap(max(ttl, @min_ttl))
  defp clamp_ttl(_), do: cap(0)

  defp cap(ttl) when ttl <= 0, do: if(max_ttl() == :infinity, do: 0, else: max_ttl())
  defp cap(ttl), do: if(max_ttl() == :infinity, do: ttl, else: min(ttl, max_ttl()))

  # 0 ttl = no expiry → expires_at 0, a sentinel the runner banner and viewer render as
  # "no expiry"; a positive ttl yields an absolute unix-second deadline.
  defp expiry_at(0), do: 0
  defp expiry_at(ttl), do: System.system_time(:second) + ttl

  defp idle_ms do
    Application.get_env(:onlytty, :idle_timeout_ms, 10 * 60 * 1000)
  end
end
