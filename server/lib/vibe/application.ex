defmodule Vibe.Application do
  # See https://hexdocs.pm/elixir/Application.html for more information on.
  @moduledoc false

  use Application

  @apns_prod "https://api.push.apple.com"
  @apns_sandbox "https://api.sandbox.push.apple.com"

  @impl true
  def start(_type, _args) do
    ensure_ets_table(:rate_limiter)
    ensure_ets_table(:channel_throttle)
    ensure_ets_table(:auth_token_cache)
    ensure_ets_table(:chat_home_cache)
    ensure_ets_table(:local_agent_worker_ratelimit)
    ensure_ets_table(:local_agent_worker_sessions)
    ensure_ets_table(:agent_bridge_pairings)
    ensure_ets_table(:agent_bridge_requests)
    ensure_ets_table(:agent_bridge_pending_tasks)
    ensure_ets_table(:vibe_mcp_tool_cache)
    ensure_ets_table(:mls_claim_quota)
    ensure_ets_table(:login_throttle)
    ensure_ets_table(:vibe_internal_nonces)
    ensure_ets_table(:agent_run_seen)
    ensure_ets_table(:agent_run_state)

    Vibe.LogScrub.install()
    Vibe.Telemetry.SlowQuery.attach()

    children =
      [
        Vibe.Repo,
        {Phoenix.PubSub, name: Vibe.PubSub},
        Vibe.Cache
      ] ++
        Vibe.Cluster.child_specs() ++
        Vibe.RateLimit.redix_child_specs() ++
        [Vibe.Telemetry.Metrics.reporter_child_spec()] ++
        Vibe.Telemetry.MetricsServer.child_specs() ++
        [
      VibeWeb.Presence,
      {Finch, name: Vibe.Finch},
      {Finch,
       name: Vibe.APNsFinch,
       pools: %{
         @apns_prod => [protocols: [:http2]],
         @apns_sandbox => [protocols: [:http2]],
         default: [protocols: [:http2]]
       }},
      VibeWeb.Endpoint,
      Vibe.RelayRegistry,
      Vibe.MeshAssembler,
      Vibe.Scheduler,
      Vibe.AgentDeliveryScheduler,
      Vibe.ChannelAgentScheduler,
      Vibe.AgentRoutineScheduler,
      Vibe.StoryCleaner,
      Vibe.Retention,
      {Task.Supervisor,
       name: Vibe.AI.WorkerTaskSupervisor, max_children: local_agent_worker_concurrency()},
      {Task.Supervisor, name: Vibe.TaskSupervisor},
      Vibe.MusicCacheFill,
      {Registry, keys: :unique, name: Vibe.AI.TeamRunRegistry},
      {DynamicSupervisor, name: Vibe.AI.TeamRunMonitorSupervisor, strategy: :one_for_one}
        ]

    opts = [strategy: :one_for_one, name: Vibe.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Task.start(fn -> Vibe.AI.LocalAgentWorker.ensure_agent_users() end)
        {:ok, pid}

      other ->
        other
    end
  end

  # Tell Phoenix to update the endpoint configuration whenever the.
  @impl true
  def config_change(changed, _new, removed) do
    VibeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp local_agent_worker_concurrency do
    case Integer.parse(System.get_env("VIBE_AGENT_WORKER_MAX_CONCURRENCY") || "") do
      {value, _} when value > 0 -> value
      _ -> 8
    end
  end

  defp ensure_ets_table(name) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [:set, :public, :named_table, {:read_concurrency, true}])

      _tid ->
        :ok
    end
  end
end
