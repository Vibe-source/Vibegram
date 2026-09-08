defmodule VibeContractsTest do
  use ExUnit.Case, async: true

  test "version constants match the frozen contract names" do
    assert VibeContracts.agentic_contract() == "vibe.agentic.v1"
    assert VibeContracts.content_contract() == "vibe.content.v1"
    assert VibeContracts.internal_auth() == "vibe-internal-auth/v1"
  end
end
