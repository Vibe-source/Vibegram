defmodule VibeContracts do
  @moduledoc "Shared, dependency-free contracts for the Vibe core and the agent runtime."

  def agentic_contract, do: "vibe.agentic.v1"
  def content_contract, do: "vibe.content.v1"
  def internal_auth, do: "vibe-internal-auth/v1"
end
