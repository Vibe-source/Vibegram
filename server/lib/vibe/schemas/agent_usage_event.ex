defmodule Vibe.AgentUsageEvent do
  @moduledoc """
  One row per metered agent run (embedded or isolated). Append-only, idempotent
  on `run_id` — see `Vibe.AgentUsage`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "agent_usage_events" do
    field :owner_user_id, :binary_id
    field :agent_id, :binary_id
    field :run_id, :binary_id
    field :day, :date
    field :source, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :sandbox_seconds, :integer, default: 0
    field :cost_cents, :integer, default: 0

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :owner_user_id,
      :agent_id,
      :run_id,
      :day,
      :source,
      :input_tokens,
      :output_tokens,
      :sandbox_seconds,
      :cost_cents
    ])
    |> validate_required([:owner_user_id, :agent_id, :day])
  end
end
