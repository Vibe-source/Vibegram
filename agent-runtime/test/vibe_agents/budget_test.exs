defmodule VibeAgents.BudgetTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import VibeAgents.Test.Fixtures

  alias VibeAgents.{Budget, Repo}
  alias VibeAgents.Schemas.AgentUsageLedger

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "a run under every ceiling passes" do
    run = insert_run!()
    assert :ok = Budget.check!(run)
  end

  test "the per-run token ceiling raises" do
    run = insert_run!()
    run = %{run | usage: %{"inputTokens" => 400_001, "outputTokens" => 0}}
    assert_raise Budget.ExceededError, fn -> Budget.check!(run) end
  end

  test "daily cents are enforced from the ledger" do
    run = insert_run!(%{"agentProfile" => agent_profile(%{"budgets" => %{"dailyCents" => 1, "monthlyCents" => nil}})})
    assert :ok = Budget.check!(run)
    cost = Budget.record_usage(run, 100_000, 100_000)
    assert cost >= 1
    assert_raise Budget.ExceededError, fn -> Budget.check!(run) end
  end

  test "token estimate is ~4 chars per token" do
    assert Budget.estimate_tokens(String.duplicate("a", 400)) == 100
  end

  test "sandbox seconds add cost cents and land in the ledger row" do
    run = insert_run!()
    cost = Budget.record_usage(run, 0, 0, 90)
    assert cost == 2

    ledger = Repo.one(from l in AgentUsageLedger, where: l.run_id == ^run.id)
    assert ledger.sandbox_seconds == 90
    assert ledger.cost_cents == 2
  end

  test "model cost still prices via VibeContracts.ModelRates after the delegation" do
    run = insert_run!()
    assert Budget.record_usage(run, 1000, 1000) == 2
  end
end
