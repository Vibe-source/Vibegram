defmodule VibeAgents.Budget do
  @moduledoc """
  Per-run token ceiling + per-agent daily/monthly cents, checked before each model call and
  each tool call (spec §3.9). Token counts are the same char/4 estimate the ported LLM loop
  uses for its live "thinking" counter — providers do not return exact counts mid-stream.
  """
  import Ecto.Query
  require Logger
  alias VibeAgents.Repo
  alias VibeAgents.Schemas.AgentUsageLedger
  alias VibeContracts.ModelRates

  defmodule ExceededError do
    defexception [:message, :which]
  end

  @doc "Raises VibeAgents.Budget.ExceededError when a ceiling is already exceeded."
  def check!(run) do
    check_run_tokens!(run)
    check_period!(run, "dailyCents", :day)
    check_period!(run, "monthlyCents", :month)
    :ok
  end

  @doc "Records one round's usage (+ optional sandbox seconds) against the run + daily ledger; returns cost in cents."
  def record_usage(run, input_tokens, output_tokens, sandbox_seconds \\ 0) do
    model_cost = cost_cents(run, input_tokens, output_tokens)
    sandbox_cost = sandbox_cost_cents(sandbox_seconds)
    cost = model_cost + sandbox_cost

    %AgentUsageLedger{}
    |> AgentUsageLedger.changeset(%{
      agent_id: run.agent_id,
      run_id: run.id,
      day: Date.utc_today(),
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      sandbox_seconds: sandbox_seconds,
      cost_cents: cost
    })
    |> Repo.insert()
    |> case do
      {:ok, _entry} ->
        :ok

      {:error, changeset} ->
        Logger.warning("[VibeAgents.Budget] usage insert failed run=#{run.id}: #{inspect(changeset.errors)}")
    end

    cost
  end

  defp sandbox_cost_cents(seconds) when is_integer(seconds) and seconds > 0 do
    per_minute = Application.get_env(:vibe_agents, :sandbox_cents_per_minute, 1)
    ceil(seconds / 60) * per_minute
  end

  defp sandbox_cost_cents(_seconds), do: 0

  @doc "Rough token count: ~4 chars/token, same heuristic as the streamed thinking counter."
  defdelegate estimate_tokens(text), to: ModelRates

  defp check_run_tokens!(run) do
    ceiling = Application.get_env(:vibe_agents, :max_run_tokens, 400_000)
    used = Map.get(run.usage || %{}, "inputTokens", 0) + Map.get(run.usage || %{}, "outputTokens", 0)

    if used > ceiling do
      raise ExceededError, message: "per-run token ceiling exceeded", which: :run_tokens
    end
  end

  defp check_period!(run, budget_key, period) do
    budgets = run.agent_profile["budgets"] || run.agent_profile[:budgets] || %{}

    case budgets[budget_key] do
      cents when is_integer(cents) and cents > 0 ->
        spent = spent_cents(run.agent_id, period)
        if spent >= cents, do: raise(ExceededError, message: "#{period} spend ceiling exceeded", which: period)

      _ ->
        :ok
    end
  end

  defp spent_cents(agent_id, :day) do
    today = Date.utc_today()

    from(l in AgentUsageLedger, where: l.agent_id == ^agent_id and l.day == ^today, select: sum(l.cost_cents))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp spent_cents(agent_id, :month) do
    today = Date.utc_today()
    start_of_month = Date.beginning_of_month(today)

    from(l in AgentUsageLedger,
      where: l.agent_id == ^agent_id and l.day >= ^start_of_month and l.day <= ^today,
      select: sum(l.cost_cents)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp cost_cents(run, input_tokens, output_tokens) do
    provider = run.agent_profile["modelProvider"] || run.agent_profile[:modelProvider] || "anthropic"
    model = run.agent_profile["modelId"] || run.agent_profile[:modelId]
    ModelRates.cost_cents(provider, model, input_tokens, output_tokens)
  end
end
