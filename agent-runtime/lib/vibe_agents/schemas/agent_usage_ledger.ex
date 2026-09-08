defmodule VibeAgents.Schemas.AgentUsageLedger do
  @moduledoc "One row per run's token/cost usage, rolled up daily per agent for budget checks."
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id

  schema "agent_usage_ledger" do
    field :agent_id, :binary_id
    field :run_id, :binary_id
    field :day, :date
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :sandbox_seconds, :integer, default: 0
    field :cost_cents, :integer, default: 0

    timestamps(updated_at: false)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:agent_id, :run_id, :day, :input_tokens, :output_tokens, :sandbox_seconds, :cost_cents])
    |> validate_required([:agent_id, :day])
  end
end
