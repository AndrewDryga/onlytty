defmodule Onlytty.Cluster.GCE do
  @moduledoc """
  A libcluster strategy that forms the BEAM cluster from the relay's GCP managed
  instance group, discovering peers via the Compute API instead of DNS.

  Each poll lists the project's RUNNING instances carrying the cluster label
  (`cluster_name=<value>`) through the Compute `aggregatedList` endpoint — which
  spans every zone, so it works for a *regional* MIG — and connects to each peer
  as `<basename>@<internal-ip>`, matching the node name set in `rel/env.sh.eex`.

  Auth uses the instance metadata-server access token (the same mechanism
  `templates/cloud-init.yaml` uses for Secret Manager): no service-account key.
  The instance template grants the `cloud-platform` scope and the VM service
  account needs `roles/compute.viewer`. No deps beyond `hackney` + `jason`,
  both already shipped.

  Topology `:config` keys:

    * `:project_id`       - **required**, GCP project to query.
    * `:cluster_label`    - label key to filter on (default `"cluster_name"`).
    * `:cluster_value`    - label value to filter on (default `"onlytty"`).
    * `:basename`         - node basename (default `"onlytty"`).
    * `:polling_interval` - ms between polls (default 30_000).
    * `:backoff_interval` - max ms backoff between discovery retries (default 1_000).
    * `:discover_fn`      - 1-arity `fn(config) -> {:ok, [instance]} | {:error, term}`;
                            a test seam that defaults to the live Compute API call.

  The connect/disconnect/retry bookkeeping follows the standard libcluster
  polling-strategy shape (`connect_nodes/4` already excludes `Node.self/0` and
  already-connected peers, so we don't filter them here).
  """
  use GenServer
  use Cluster.Strategy

  alias Cluster.Strategy.State

  require Logger

  @default_polling_interval :timer.seconds(30)
  @metadata_token_url "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init([%State{} = state]) do
    {:ok, %State{state | meta: MapSet.new()}, {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, %State{} = state), do: {:noreply, poll(state)}

  @impl true
  def handle_info(:poll, %State{} = state), do: {:noreply, poll(state)}

  # ── Discovery (overridable in tests via :discover_fn) ──────────────────────

  @doc false
  def list_cluster_nodes(%State{config: config}) do
    discover_fn = Keyword.get(config, :discover_fn, &__MODULE__.discover/1)
    basename = Keyword.get(config, :basename, "onlytty")

    with {:ok, instances} <- discover_fn.(config) do
      {:ok, nodes_from_instances(instances, basename)}
    end
  end

  @doc false
  def nodes_from_instances(instances, basename) do
    Enum.flat_map(instances, fn
      %{"networkInterfaces" => [%{"networkIP" => ip} | _]} -> [:"#{basename}@#{ip}"]
      _ -> []
    end)
  end

  @doc false
  # Live discovery: list this project's RUNNING instances carrying the cluster
  # label via the Compute aggregatedList API (all zones → regional-MIG-safe).
  def discover(config) do
    project_id = Keyword.fetch!(config, :project_id)
    label = Keyword.get(config, :cluster_label, "cluster_name")
    value = Keyword.get(config, :cluster_value, "onlytty")

    with {:ok, token} <- fetch_access_token(),
         {:ok, body} <- aggregated_list(project_id, label, value, token),
         {:ok, %{"items" => items}} <- Jason.decode(body) do
      instances =
        Enum.flat_map(items, fn
          {_zone, %{"instances" => instances}} -> instances
          {_zone, _no_results_on_page} -> []
        end)

      {:ok, instances}
    end
  end

  defp fetch_access_token do
    with {:ok, body} <- http_get(@metadata_token_url, [{"Metadata-Flavor", "Google"}]),
         {:ok, %{"access_token" => token}} <- Jason.decode(body) do
      {:ok, token}
    else
      {:ok, other} -> {:error, {:unexpected_token_response, other}}
      {:error, _reason} = error -> error
    end
  end

  defp aggregated_list(project_id, label, value, token) do
    filter = "labels.#{label}=#{value} AND status=RUNNING"

    url =
      "https://compute.googleapis.com/compute/v1/projects/#{project_id}/aggregated/instances?" <>
        URI.encode_query(%{"filter" => filter})

    http_get(url, [{"Authorization", "Bearer #{token}"}])
  end

  defp http_get(url, headers) do
    case :hackney.request(:get, url, headers, "", [:with_body]) do
      {:ok, 200, _headers, body} -> {:ok, body}
      {:ok, status, _headers, body} -> {:error, {:http_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Connect / disconnect bookkeeping ───────────────────────────────────────

  defp poll(%State{} = state) do
    case fetch_nodes(state) do
      {:ok, nodes} -> reconcile(state, MapSet.new(nodes))
      {:error, _reason} -> schedule_next_poll(state) && state
    end
  end

  defp reconcile(%State{topology: topology, meta: known} = state, discovered) do
    removed = MapSet.difference(known, discovered)
    added = MapSet.difference(discovered, known)

    known =
      case Cluster.Strategy.disconnect_nodes(
             topology,
             state.disconnect,
             state.list_nodes,
             MapSet.to_list(removed)
           ) do
        :ok ->
          discovered

        {:error, bad_nodes} ->
          Logger.warning("can't disconnect from some nodes", nodes: inspect(bad_nodes))
          # keep the nodes we failed to drop, so the next poll retries the disconnect
          Enum.reduce(bad_nodes, discovered, fn {node, _}, acc -> MapSet.put(acc, node) end)
      end

    known =
      case Cluster.Strategy.connect_nodes(
             topology,
             state.connect,
             state.list_nodes,
             MapSet.to_list(added)
           ) do
        :ok ->
          known

        {:error, bad_nodes} ->
          Logger.warning("can't connect to some nodes", nodes: inspect(bad_nodes))
          # forget the nodes we failed to reach, so the next poll retries the connect
          Enum.reduce(bad_nodes, known, fn {node, _}, acc -> MapSet.delete(acc, node) end)
      end

    schedule_next_poll(state)
    %State{state | meta: known}
  end

  defp fetch_nodes(%State{config: config} = state, remaining_retries \\ 3) do
    case list_cluster_nodes(state) do
      {:ok, nodes} ->
        Logger.debug("discovered #{length(nodes)} cluster node(s)", nodes: inspect(nodes))
        {:ok, nodes}

      {:error, reason} when remaining_retries > 0 ->
        Logger.warning("cluster discovery failed; retrying", reason: inspect(reason))
        backoff = :rand.uniform(Keyword.get(config, :backoff_interval, 1_000)) + 1
        Process.sleep(backoff)
        fetch_nodes(state, remaining_retries - 1)

      {:error, reason} ->
        Logger.error("cluster discovery failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp schedule_next_poll(%State{config: config}) do
    interval = Keyword.get(config, :polling_interval, @default_polling_interval)
    Process.send_after(self(), :poll, interval)
  end
end
