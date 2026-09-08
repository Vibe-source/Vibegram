import Config

config :vibe, Vibe.Repo,
  username: System.get_env("DB_USER") || "postgres",
  password: System.get_env("DB_PASS") || "postgres",
  hostname: System.get_env("DB_HOST") || "localhost",
  database: System.get_env("DB_TEST_DATABASE") || "vibe_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :vibe, VibeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_test_secret_key_base_test_secret_key_base",
  server: false

config :vibe, :background_jobs, false
config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
