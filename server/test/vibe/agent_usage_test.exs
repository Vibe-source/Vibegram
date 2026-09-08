defmodule Vibe.AgentUsageTest do
  @moduledoc "Entitlement check + idempotent usage recording."

  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.AgentUsage
  alias Vibe.AgentUsageEvent
  alias Vibe.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    owner = insert_user("usage_owner")
    agent = insert_agent(owner)
    %{owner: owner, agent: agent}
  end

  test "check_entitlement(nil) is always ok" do
    assert AgentUsage.check_entitlement(nil) == :ok
  end

  test "entitlement: ok below the monthly credit, exhausted at it", %{owner: owner, agent: agent} do
    assert AgentUsage.check_entitlement(owner.id) == :ok

    assert {:ok, _} =
             AgentUsage.record(%{
               owner_user_id: owner.id,
               agent_id: agent.id,
               run_id: Ecto.UUID.generate(),
               day: Date.utc_today(),
               cost_cents: AgentUsage.monthly_credit_cents(owner.id)
             })

    assert AgentUsage.check_entitlement(owner.id) == {:error, :agent_credits_exhausted}
  end

  test "record/1 is idempotent on run_id", %{owner: owner, agent: agent} do
    run_id = Ecto.UUID.generate()
    attrs = %{owner_user_id: owner.id, agent_id: agent.id, run_id: run_id, day: Date.utc_today(), cost_cents: 10}

    assert {:ok, _} = AgentUsage.record(attrs)
    assert {:ok, _} = AgentUsage.record(Map.put(attrs, :cost_cents, 999))

    assert Repo.aggregate(AgentUsageEvent, :count) == 1
    assert AgentUsage.month_spent_cents(owner.id) == 10
  end

  test "record_embedded prices tokens via ModelRates and is idempotent on the turn id", %{agent: agent} do
    run_id = Ecto.UUID.generate()

    assert {:ok, _} = AgentUsage.record_embedded(agent, run_id, 100, 50)
    assert {:ok, _} = AgentUsage.record_embedded(agent, run_id, 100, 50)

    assert Repo.aggregate(AgentUsageEvent, :count) == 1
    assert AgentUsage.agent_summary(agent.id)["runsToday"] == 1
  end

  test "record_run_completed pulls usage/cost/sandboxSeconds off the RunEvent payload", %{owner: owner, agent: agent} do
    event = %{
      "runId" => Ecto.UUID.generate(),
      "payload" => %{
        "usage" => %{"inputTokens" => 10, "outputTokens" => 20},
        "costCents" => 42,
        "sandboxSeconds" => 5
      }
    }

    assert {:ok, _} = AgentUsage.record_run_completed(agent, event)

    summary = AgentUsage.agent_summary(agent.id)
    assert summary["monthCents"] == 42
    assert summary["monthInputTokens"] == 10
    assert summary["monthOutputTokens"] == 20
    assert summary["monthSandboxSeconds"] == 5
    assert AgentUsage.owner_summary(owner.id)["monthUsedCents"] == 42
  end

  test "owner_summary shape", %{owner: owner} do
    summary = AgentUsage.owner_summary(owner.id)
    assert Map.keys(summary) |> Enum.sort() == ["monthCreditCents", "monthUsedCents", "remainingCents", "todayUsedCents"] |> Enum.sort()
    assert summary["remainingCents"] == summary["monthCreditCents"] - summary["monthUsedCents"]
  end

  defp insert_user(prefix) do
    suffix = System.unique_integer([:positive])

    Repo.insert!(%User{
      id: Ecto.UUID.generate(),
      username: "#{prefix}_#{suffix}",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}",
      name: "Usage"
    })
  end

  defp insert_agent(owner) do
    shadow =
      Repo.insert!(%User{
        id: Ecto.UUID.generate(),
        username: "usageagent_#{System.unique_integer([:positive])}",
        password_hash: "hash",
        public_key: "key",
        device_id: "d",
        is_agent: true,
        name: "Bot"
      })

    Repo.insert!(%Agent{
      owner_user_id: owner.id,
      agent_user_id: shadow.id,
      status: "published",
      display_name: "Usage Bot",
      enabled_tools: [],
      output_modes: ["text"],
      webhook_secret_hash: "hash",
      secret_hint: "hint"
    })
    |> Repo.preload(:agent_user)
  end
end
