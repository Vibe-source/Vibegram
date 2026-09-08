defmodule VibeAgents.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    VibeAgentsWeb.Plugs.PublicRateLimit.init_table()

    children = [
      VibeAgents.Repo,
      {Phoenix.PubSub, name: VibeAgents.PubSub},
      {Finch, name: VibeAgents.Finch},
      {Registry, keys: :unique, name: VibeAgents.Runs.Registry},
      {DynamicSupervisor, name: VibeAgents.Runs.Supervisor, strategy: :one_for_one},
      {Task.Supervisor, name: VibeAgents.TaskSupervisor},
      VibeAgents.Outbox,
      VibeAgents.Retention,
      VibeAgents.Runs.Dispatcher,
      VibeAgents.Runs.Resumer,
      VibeAgents.Runs.Janitor,
      {Registry, keys: :unique, name: VibeAgents.Voice.Registry},
      {DynamicSupervisor, name: VibeAgents.Voice.Supervisor, strategy: :one_for_one},
      VibeAgents.Voice.Sessions,
      VibeAgentsWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: VibeAgents.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    VibeAgentsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
