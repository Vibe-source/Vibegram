import Config

config :vibe_agents, VibeAgents.Repo,
  username: System.get_env("DB_USER") || "postgres",
  password: System.get_env("DB_PASS") || "postgres",
  hostname: System.get_env("DB_HOST") || "localhost",
  database: System.get_env("DB_NAME") || "vibe_agents_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  prepare: :unnamed

config :vibe_agents, VibeAgentsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4100")],
  check_origin: false,
  debug_errors: true,
  secret_key_base:
    "DEV_SECRET_KEY_CHANGE_ME_IN_PROD_BUT_OK_FOR_DEV_Generate_With_mix_phx_gen_secret_agents"

config :vibe_agents, :internal_hmac_key,
  System.get_env("VIBE_INTERNAL_HMAC_KEY") || "dev-only-internal-hmac-key-not-for-prod-use!!"

config :logger, :console, level: :info
