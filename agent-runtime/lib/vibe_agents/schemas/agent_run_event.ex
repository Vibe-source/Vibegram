defmodule VibeAgents.Schemas.AgentRunEvent do
  @moduledoc "Append-only log of one run's RunEvents, ordered by seq."
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id

  schema "agent_run_events" do
    field :run_id, :binary_id
    field :seq, :integer
    field :kind, :string
    field :payload, :map, default: %{}
    field :ts, :integer

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:run_id, :seq, :kind, :payload, :ts])
    |> validate_required([:run_id, :seq, :kind, :ts])
    |> unique_constraint([:run_id, :seq])
  end
end
