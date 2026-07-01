defmodule OnlyTTY.Drain do
  @moduledoc """
  Graceful shutdown for a relay node. On SIGTERM (a deploy draining/replacing the
  instance) we don't hard-cut live sessions: we flip `/healthz` to 503 (so the load
  balancer stops sending new connections here), tell every connected runner/viewer the
  node is going away (so they reconnect elsewhere — claim-based resume re-establishes
  the same session on a surviving node), wait a short grace, then stop.

  Wired only in prod via `install/0` (gated by `:drain_on_sigterm`, set in runtime.exs)
  so dev/test signal handling is untouched. Per Elixir's `System.trap_signal/3`, the
  registered function runs before OTP's default shutdown. `run/0` is never called from
  tests (it stops the VM) — its parts are tested instead.
  """

  require Logger

  @flag {__MODULE__, :draining}
  @default_grace_ms 10_000

  @doc "Register the SIGTERM handler. Call once at boot (prod only)."
  def install do
    case System.trap_signal(:sigterm, :onlytty_drain, &__MODULE__.run/0) do
      {:ok, _ref} ->
        Logger.info("drain: SIGTERM handler installed")
        :ok

      {:error, reason} ->
        # e.g. :not_sup where OS signals aren't available — degrade to a plain stop.
        Logger.warning("drain: could not install SIGTERM handler", reason: inspect(reason))
        {:error, reason}
    end
  end

  @doc "Whether this node is draining; `/healthz` returns 503 while true."
  def draining?, do: :persistent_term.get(@flag, false)

  @doc false
  def mark_draining, do: :persistent_term.put(@flag, true)

  @doc false
  def clear_draining, do: :persistent_term.erase(@flag)

  # The SIGTERM handler body: stop taking new connections, tell connected clients to
  # migrate, give them a grace window, then shut down. NEVER call this from a test.
  @doc false
  def run do
    Logger.info("drain: SIGTERM received — draining before shutdown")
    mark_draining()
    notify_local_sessions()
    Process.sleep(grace_ms())
    System.stop()
    :ok
  end

  @doc "Tell every session on THIS node to send its sockets a `going_away` nudge."
  def notify_local_sessions do
    OnlyTTY.SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_, pid, _type, _modules} when is_pid(pid) -> OnlyTTY.Session.drain(pid)
      _ -> :ok
    end)
  end

  defp grace_ms, do: Application.get_env(:onlytty, :drain_grace_ms, @default_grace_ms)
end
