defmodule VibeContracts.MixProject do
  use Mix.Project

  def project do
    [
      app: :vibe_contracts,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {VibeContracts.Application, []}]
  end

  defp deps do
    [
      {:jason, "~> 1.2"}
    ]
  end
end
