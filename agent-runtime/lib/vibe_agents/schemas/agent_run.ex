defmodule VibeAgents.Schemas.AgentRun do
  @moduledoc "One agent run: durable state for the loop, resumable across restarts."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(queued running waiting_approval waiting_ask waiting_permission completed failed cancelled)
  @waiting_statuses ~w(waiting_approval waiting_ask waiting_permission)

  schema "agent_runs" do
    field :agent_id, :binary_id
    field :agent_user_id, :binary_id
    field :owner_user_id, :binary_id
    field :requester_user_id, :binary_id
    field :chat_id, :string
    field :chat_kind, :string
    field :source, :string
    field :parent_run_id, :binary_id
    field :idempotency_key, :string
    field :status, :string, default: "queued"
    field :input, :map, default: %{}
    field :agent_profile, :map, default: %{}
    field :context, :map, default: %{}
    field :capabilities, :map, default: %{}
    field :state, :map, default: %{}
    field :result, :map
    field :error, :string
    field :usage, :map, default: %{}
    field :cost_cents, :integer, default: 0
    field :steps, :integer, default: 0
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    timestamps()
  end

  def statuses, do: @statuses
  def waiting_statuses, do: @waiting_statuses
  def waiting?(%__MODULE__{status: status}), do: status in @waiting_statuses

  @doc "Fields accepted from a RunRequest at creation time."
  def create_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :id,
      :agent_id,
      :agent_user_id,
      :owner_user_id,
      :requester_user_id,
      :chat_id,
      :chat_kind,
      :source,
      :parent_run_id,
      :idempotency_key,
      :input,
      :agent_profile,
      :context,
      :capabilities
    ])
    |> validate_required([:agent_id, :agent_user_id, :owner_user_id, :chat_id, :source])
    |> validate_inclusion(:source, ~w(chat provider schedule voice handoff))
    |> unique_constraint(:idempotency_key)
  end

  def update_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :status,
      :state,
      :result,
      :error,
      :usage,
      :cost_cents,
      :steps,
      :started_at,
      :finished_at
    ])
    |> validate_inclusion(:status, @statuses)
  end
end
