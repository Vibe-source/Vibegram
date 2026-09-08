import Config

# Provider/service config is read here (not compile-time) so every env can.

config :vibe_agents, :core_internal_url, System.get_env("VIBE_CORE_INTERNAL_URL")
config :vibe_agents, :anthropic_api_key, System.get_env("ANTHROPIC_API_KEY")
config :vibe_agents, :openai_api_key, System.get_env("OPENAI_API_KEY")
config :vibe_agents, :tavily_api_key, System.get_env("TAVILY_API_KEY")
config :vibe_agents, :sandbox_gateway_url, System.get_env("SANDBOX_GATEWAY_URL")
config :vibe_agents, :sandbox_gateway_token, System.get_env("SANDBOX_GATEWAY_TOKEN")
config :vibe_agents, :public_url, System.get_env("VIBE_AGENTS_PUBLIC_URL")
config :vibe_agents, :kill_switch, System.get_env("VIBE_AGENTS_KILL_SWITCH") in ["1", "true"]

parse_int = fn name, default ->
  case Integer.parse(System.get_env(name) || "") do
    {value, _} when value > 0 -> value
    _ -> default
  end
end

config :vibe_agents, :max_steps, parse_int.("VIBE_AGENTS_MAX_STEPS", 24)
config :vibe_agents, :max_run_seconds, parse_int.("VIBE_AGENTS_MAX_RUN_SECONDS", 1200)
config :vibe_agents, :max_run_tokens, parse_int.("VIBE_AGENTS_MAX_RUN_TOKENS", 400_000)
config :vibe_agents, :max_tool_failures, parse_int.("VIBE_AGENTS_MAX_TOOL_FAILURES", 6)
config :vibe_agents, :max_handoff_depth, parse_int.("VIBE_AGENTS_MAX_HANDOFF_DEPTH", 4)
# Live run servers at once.
config :vibe_agents, :max_concurrent_runs, parse_int.("VIBE_AGENTS_MAX_CONCURRENT_RUNS", 8)

config :vibe_agents, :voice_model, System.get_env("VIBE_VOICE_MODEL") || "gpt-realtime"
config :vibe_agents, :voice_voice, System.get_env("VIBE_VOICE_VOICE") || "marin"
config :vibe_agents, :voice_max_seconds, parse_int.("VIBE_VOICE_MAX_SECONDS", 1800)

if hmac_key = System.get_env("VIBE_INTERNAL_HMAC_KEY") do
  config :vibe_agents, :internal_hmac_key, hmac_key
end

if System.get_env("PORT") do
  config :vibe_agents, VibeAgentsWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT"))]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing"

  config :vibe_agents, VibeAgents.Repo,
    url: database_url,
    prepare: :unnamed,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: if(System.get_env("ECTO_IPV6") in ["true", "1"], do: [:inet6], else: [])

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing"

  ranch_max_connections = String.to_integer(System.get_env("RANCH_MAX_CONNECTIONS") || "16384")

  config :vibe_agents, VibeAgentsWeb.Endpoint,
    url: [host: System.get_env("VIBE_AGENTS_HOST") || "example.com", port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT") || "4100"),
      transport_options: [max_connections: ranch_max_connections]
    ],
    secret_key_base: secret_key_base,
    server: true
end
