import Config

config :vibe_agents,
  ecto_repos: [VibeAgents.Repo],
  generators: [timestamp_type: :utc_datetime]

config :vibe_agents, VibeAgentsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [formats: [json: VibeAgentsWeb.ErrorJSON], layout: false],
  pubsub_server: VibeAgents.PubSub

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
