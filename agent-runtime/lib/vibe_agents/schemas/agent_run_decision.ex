defmodule VibeAgents.Schemas.AgentRunDecision do
  @moduledoc "One pending/resolved approval, ask, or permission gate for a run."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(approval ask permission)
  @statuses ~w(pending resolved expired)

  schema "agent_run_decisions" do
    field :run_id, :binary_id
    field :kind, :string
    field :status, :string, default: "pending"
    field :request, :map, default: %{}
    field :outcome, :string
    field :answer, :map
    field :actor_user_id, :binary_id
    field :expires_at, :utc_datetime
    field :resolved_at, :utc_datetime

    timestamps()
  end

  def kinds, do: @kinds

  def create_changeset(decision, attrs) do
    decision
    |> cast(attrs, [:id, :run_id, :kind, :request, :expires_at])
    |> validate_required([:run_id, :kind, :request])
    |> validate_inclusion(:kind, @kinds)
  end

  def resolve_changeset(decision, attrs) do
    decision
    |> cast(attrs, [:status, :outcome, :answer, :actor_user_id, :resolved_at])
    |> validate_inclusion(:status, @statuses)
  end
end
