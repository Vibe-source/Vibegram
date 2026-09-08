defmodule Vibe.AgentUsage do
  @moduledoc """
  Per-owner agent usage metering (embedded + isolated) and monthly credit entitlement.
  """

  require Logger
  import Ecto.Query

  alias Vibe.Agent
  alias Vibe.AgentUsageEvent
  alias Vibe.Repo
  alias Vibe.Subscriptions

  @default_credits %{"free" => 100, "bronze" => 500, "silver" => 2000, "gold" => 10000}

  @doc "Idempotent insert on run_id (on_conflict: :nothing). Never raises."
  def record(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    changeset = AgentUsageEvent.changeset(%AgentUsageEvent{}, attrs)

    opts =
      if attrs["run_id"] not in [nil, ""] do
        [on_conflict: :nothing, conflict_target: :run_id]
      else
        []
      end

    case Repo.insert(changeset, opts) do
      {:ok, event} ->
        {:ok, event}

      {:error, reason} ->
        Logger.warning("[AgentUsage] record failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Records a completed isolated run from a validated RunEvent map."
  def record_run_completed(%Agent{} = agent, event) when is_map(event) do
    payload = event["payload"] || %{}
    usage = payload["usage"] || %{}

    record(%{
      "owner_user_id" => agent.owner_user_id,
      "agent_id" => agent.id,
      "run_id" => event["runId"],
      "day" => Date.utc_today(),
      "source" => "isolated",
      "input_tokens" => usage["inputTokens"] || 0,
      "output_tokens" => usage["outputTokens"] || 0,
      "sandbox_seconds" => payload["sandboxSeconds"] || 0,
      "cost_cents" => payload["costCents"] || 0
    })
  end

  @doc "Records a completed embedded turn, pricing tokens via VibeContracts.ModelRates."
  def record_embedded(%Agent{} = agent, run_id, input_tokens, output_tokens) do
    cost_cents =
      VibeContracts.ModelRates.cost_cents(
        agent.model_provider,
        agent.model_id,
        input_tokens,
        output_tokens
      )

    record(%{
      "owner_user_id" => agent.owner_user_id,
      "agent_id" => agent.id,
      "run_id" => run_id,
      "day" => Date.utc_today(),
      "source" => "embedded",
      "input_tokens" => input_tokens,
      "output_tokens" => output_tokens,
      "cost_cents" => cost_cents
    })
  end

  def month_spent_cents(owner_user_id) do
    today = Date.utc_today()
    start = Date.beginning_of_month(today)

    Repo.one(
      from e in AgentUsageEvent,
        where: e.owner_user_id == ^owner_user_id and e.day >= ^start and e.day <= ^today,
        select: sum(e.cost_cents)
    ) || 0
  end

  def today_spent_cents(owner_user_id) do
    today = Date.utc_today()

    Repo.one(
      from e in AgentUsageEvent,
        where: e.owner_user_id == ^owner_user_id and e.day == ^today,
        select: sum(e.cost_cents)
    ) || 0
  end

  def monthly_credit_cents(owner_user_id) do
    tier = Subscriptions.calculate_user_tier(owner_user_id)
    credits = Application.get_env(:vibe, :agent_credits, @default_credits)
    Map.get(credits, tier, Map.get(@default_credits, tier, 100))
  end

  @doc "nil owner (system/ownerless callers) is never blocked."
  def check_entitlement(nil), do: :ok

  def check_entitlement(owner_user_id) do
    if month_spent_cents(owner_user_id) < monthly_credit_cents(owner_user_id) do
      :ok
    else
      {:error, :agent_credits_exhausted}
    end
  end

  def owner_summary(owner_user_id) do
    used = month_spent_cents(owner_user_id)
    credit = monthly_credit_cents(owner_user_id)

    %{
      "monthUsedCents" => used,
      "monthCreditCents" => credit,
      "todayUsedCents" => today_spent_cents(owner_user_id),
      "remainingCents" => max(credit - used, 0)
    }
  end

  def agent_summary(agent_id) do
    today = Date.utc_today()
    start = Date.beginning_of_month(today)

    month =
      Repo.one(
        from e in AgentUsageEvent,
          where: e.agent_id == ^agent_id and e.day >= ^start and e.day <= ^today,
          select: %{
            cost_cents: sum(e.cost_cents),
            input_tokens: sum(e.input_tokens),
            output_tokens: sum(e.output_tokens),
            sandbox_seconds: sum(e.sandbox_seconds)
          }
      )

    today_row =
      Repo.one(
        from e in AgentUsageEvent,
          where: e.agent_id == ^agent_id and e.day == ^today,
          select: %{cost_cents: sum(e.cost_cents), runs: count(e.id)}
      )

    %{
      "todayCents" => today_row.cost_cents || 0,
      "monthCents" => month.cost_cents || 0,
      "monthInputTokens" => month.input_tokens || 0,
      "monthOutputTokens" => month.output_tokens || 0,
      "monthSandboxSeconds" => month.sandbox_seconds || 0,
      "runsToday" => today_row.runs || 0
    }
  end
end
