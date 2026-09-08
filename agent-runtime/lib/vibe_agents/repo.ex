defmodule VibeAgents.Repo do
  use Ecto.Repo,
    otp_app: :vibe_agents,
    adapter: Ecto.Adapters.Postgres
end
