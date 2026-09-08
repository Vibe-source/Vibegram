import Config

config :vibe_agents, VibeAgents.Repo,
  username: System.get_env("DB_USER") || "postgres",
  password: System.get_env("DB_PASS") || "postgres",
  hostname: System.get_env("DB_HOST") || "localhost",
  database: System.get_env("DB_TEST_DATABASE") || "vibe_agents_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  prepare: :unnamed

config :vibe_agents, VibeAgentsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4102],
  secret_key_base:
    "test_secret_key_base_test_secret_key_base_test_secret_key_base_agents",
  server: false

# Deterministic auth/broker tests:
config :vibe_agents, :internal_hmac_key, "test-internal-hmac-key-at-least-32-bytes-long!!"
# No background pollers under the sandboxed Repo.
config :vibe_agents, :background_jobs, false
config :vibe_agents, :llm_module, VibeAgents.LLM.FakeLoop
config :vibe_agents, :core_http, VibeAgents.Test.FakeCoreHTTP
config :vibe_agents, :sandbox_http, VibeAgents.Test.FakeSandboxHTTP

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
