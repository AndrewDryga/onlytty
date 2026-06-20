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

  # PROTOCOL.md: default 1800s, max 604800 (7d — sessions are long-lived and survive
  # runner reconnects, so the ceiling is days, not hours). We also clamp a sane lower
  # bound so a session can't expire before anyone can connect. Both the default and
  # the max are overridable at runtime via the :default_ttl / :max_ttl app env
  # (ONLYTTY_DEFAULT_TTL / ONLYTTY_MAX_TTL).
  @default_ttl 1800
  @min_ttl 60
  @max_ttl 604_800

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
        {:ok,
         %{id: id, runner_token: runner_token, expires_at: System.system_time(:second) + ttl}}

      {:error, :max_children} ->
        # The cap is hit: refuse rather than grow unbounded.
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

  defp clamp_ttl(nil), do: default_ttl()
  defp clamp_ttl(ttl) when is_integer(ttl), do: ttl |> max(@min_ttl) |> min(max_ttl())
  defp clamp_ttl(_), do: default_ttl()

  defp idle_ms do
    Application.get_env(:onlytty, :idle_timeout_ms, 10 * 60 * 1000)
  end
end
