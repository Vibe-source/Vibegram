defmodule VibeContracts.ModelRatesTest do
  use ExUnit.Case, async: true
  alias VibeContracts.ModelRates

  test "cost_cents prices a known model at its rate, rounded up to whole cents" do
    assert ModelRates.cost_cents("anthropic", "claude-sonnet-5", 1000, 1000) == 2
  end

  test "cost_cents falls back to the default rate for an unknown or nil model" do
    assert ModelRates.cost_cents("anthropic", "no-such-model", 1000, 1000) == 2
    assert ModelRates.cost_cents(nil, nil, 1000, 1000) == 2
  end

  test "cost_cents is zero for zero tokens" do
    assert ModelRates.cost_cents("anthropic", "claude-sonnet-5", 0, 0) == 0
  end

  test "estimate_tokens is ~4 chars per token for binaries" do
    assert ModelRates.estimate_tokens(String.duplicate("a", 400)) == 100
  end

  test "estimate_tokens inspects non-binary input first" do
    assert ModelRates.estimate_tokens(%{a: 1}) == ModelRates.estimate_tokens(inspect(%{a: 1}))
  end
end
