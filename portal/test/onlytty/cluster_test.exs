defmodule Onlytty.ClusterTest do
  # Proves the scaling property: a session created on one relay node is registered
  # CLUSTER-WIDE (via :global) and is both discoverable and reachable from another
  # node — so a runner and a viewer that land on different MIG instances still pair.
  # Without this, sessions were node-local and the MIG had to stay size 1.
  #
  # Uses a real peer node (:peer). Where the environment can't bring up distribution
  # (no epmd), the test logs and soft-skips rather than failing the gate.
  use ExUnit.Case, async: false

  alias Onlytty.SessionStore

  @moduletag :cluster

  test "a session on a peer node is registered and reachable cluster-wide via :global" do
    if ensure_distribution() do
      {:ok, peer, peer_node} = start_peer()
      on_exit(fn -> safe_stop(peer) end)

      id = "cluster-" <> Integer.to_string(System.unique_integer([:positive]))
      opts = [id: id, runner_token: "tok", ttl_seconds: 0, idle_ms: 60_000]

      # Start a real Session on the OTHER node, under the exact :global name the store
      # uses. (GenServer.start, not start_link, so it outlives the :peer.call; lib-only
      # modules so the peer can load them — ExUnit test modules aren't on the code path.)
      assert {:ok, _peer_pid} =
               :peer.call(peer, GenServer, :start, [
                 Onlytty.Session,
                 opts,
                 [name: SessionStore.name(id)]
               ])

      # From THIS node, the cluster-wide registry resolves it...
      pid =
        wait_for(fn ->
          case SessionStore.lookup(id) do
            {:ok, pid} -> pid
            :error -> nil
          end
        end)

      assert is_pid(pid), "session created on the peer was not found via :global from this node"

      assert node(pid) == peer_node,
             "session must live on the peer node (proves cross-node registration)"

      # ...and it's reachable across nodes: a cross-node OTP call returns its own state.
      assert :sys.get_state(pid).id == id
    else
      IO.puts("[cluster_test] distribution unavailable (no epmd) — skipping the peer-node check")
    end
  end

  test "a runner re-claims its id on this node after the peer holding it dies (deploy resume)" do
    if ensure_distribution() do
      {:ok, peer, _peer_node} = start_peer()
      on_exit(fn -> safe_stop(peer) end)

      id = "resume-" <> Integer.to_string(System.unique_integer([:positive]))
      token = "tok-" <> Integer.to_string(System.unique_integer([:positive]))
      opts = [id: id, runner_token: token, ttl_seconds: 0, idle_ms: 60_000]

      # The session lives on the PEER node (as if the runner first landed there).
      assert {:ok, _pid} =
               :peer.call(peer, GenServer, :start, [
                 Onlytty.Session,
                 opts,
                 [name: SessionStore.name(id)]
               ])

      assert is_pid(
               wait_for(fn ->
                 case SessionStore.lookup(id) do
                   {:ok, p} -> p
                   :error -> nil
                 end
               end)
             )

      # The node holding the session dies — a deploy drains/replaces it.
      safe_stop(peer)

      # :global drops the dead node's registration, so the id is free to re-claim.
      assert wait_for(fn -> if SessionStore.lookup(id) == :error, do: true, else: nil end)

      # The runner re-claims the SAME id+token; it now lands on THIS node and continues.
      assert {:ok, %{id: ^id}} = SessionStore.create_or_attach(id, token, ttl_seconds: 0)
      assert {:ok, pid} = SessionStore.lookup(id)
      assert node(pid) == node(), "the re-claimed session must now live on this node"

      # The token still gates re-claims: a different runner cannot steal the id.
      assert {:error, :unauthorized} =
               SessionStore.create_or_attach(id, "wrong-token-aaaaaaaa", [])
    else
      IO.puts("[cluster_test] distribution unavailable (no epmd) — skipping the resume check")
    end
  end

  # --- helpers ---------------------------------------------------------------

  @cookie :onlytty_cluster_test

  # Bring the test node up as a distributed node so :peer can spawn a sibling. Pin a
  # fixed cookie on both ends — net_kernel otherwise auto-generates an in-memory cookie
  # the freshly-spawned peer beam doesn't share, so distribution wouldn't connect.
  defp ensure_distribution do
    _ = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    started =
      case :net_kernel.start(:"onlytty_primary@127.0.0.1", %{name_domain: :longnames}) do
        {:ok, _} -> true
        {:error, {:already_started, _}} -> true
        _ -> Node.alive?()
      end

    if started, do: :erlang.set_cookie(@cookie)
    started
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp start_peer do
    # Control the peer over its stdio channel (reliable regardless of the dist mesh),
    # then have the peer dial the primary so the two share a :global cluster.
    {:ok, peer, node} =
      :peer.start_link(%{
        name: :"onlytty_peer_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        connection: :standard_io,
        args: [~c"-setcookie", Atom.to_charlist(@cookie)]
      })

    # The peer needs our compiled modules (Session, SessionStore, this test) to run them.
    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
    true = :peer.call(peer, Node, :connect, [node()])
    {:ok, peer, node}
  end

  defp safe_stop(peer) do
    :peer.stop(peer)
  catch
    _, _ -> :ok
  end

  defp wait_for(fun, tries \\ 100) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(20)
        wait_for(fun, tries - 1)

      result ->
        result
    end
  end
end
