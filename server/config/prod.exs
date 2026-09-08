import Config

# We configure the endpoint for production here.

config :vibe, VibeWeb.Endpoint,
  url: [host: "example.com", port: 80]

# Do not print debug messages in production
config :logger, level: :info
