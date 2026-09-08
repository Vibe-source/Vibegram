defmodule Vibe.Cluster do
  @moduledoc """
  libcluster topology selected by CLUSTER_STRATEGY (none default | gossip | dns).
  `child_specs/0` returns the Cluster.Supervisor child for application.ex, or `[]` when.
  """

  def strategy, do: System.get_env("CLUSTER_STRATEGY") || "none"

  def topologies do
    case strategy() do
      "gossip" ->
        [vibe: [strategy: Cluster.Strategy.Gossip]]

      "dns" ->
        [
          vibe: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              polling_interval: 5_000,
              query: System.get_env("CLUSTER_DNS_QUERY") || "vibe-core",
              node_basename: System.get_env("CLUSTER_NODE_BASENAME") || "vibe"
            ]
          ]
        ]

      _ ->
        []
    end
  end

  @doc "Cluster.Supervisor child spec list for application.ex — empty when strategy is none."
  def child_specs do
    case topologies() do
      [] -> []
      topologies -> [{Cluster.Supervisor, [topologies, [name: Vibe.ClusterSupervisor]]}]
    end
  end
end
