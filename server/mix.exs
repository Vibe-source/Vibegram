defmodule Vibe.MixProject do
  use Mix.Project

  def project do
    [
      app: :vibe,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Vibe.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7.0"},
      {:phoenix_ecto, "~> 4.4"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:swoosh, "~> 1.3"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:plug_cowboy, "~> 2.5"},
      {:cors_plug, "~> 3.0"},
      {:pbkdf2_elixir, "~> 2.0"},
      {:uuid, "~> 1.1"},
      {:gettext, "~> 0.20"},
      {:phoenix_html, "~> 3.3"},
      {:phoenix_live_view, "~> 0.19.0"},
      {:phoenix_live_reload, "~> 1.4", only: :dev},
      {:hackney, "~> 1.9"},
      {:finch, "~> 0.18"},
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:vibe_contracts, path: "../contracts"},
      {:redix, "~> 1.5"},
      {:libcluster, "~> 3.4"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
