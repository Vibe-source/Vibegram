defmodule Vibe.AgentApprovalTask do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w[pending approved rejected expired]
  @action_modes ~w[single multi]
  @sources ~w[runbook declared runtime]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_approval_tasks" do
    field :chat_id, :string
    field :requested_action, :map, default: %{}
    field :rationale, :string
    field :status, :string, default: "pending"
    field :decision_note, :string
    field :decided_at, :utc_datetime
    field :action_mode, :string, default: "single"
    field :expires_at, :utc_datetime
    field :message_id, :binary_id
    field :chosen_action_id, :string
    field :source, :string, default: "runbook"

    belongs_to :agent, Vibe.Agent
    belongs_to :thread, Vibe.AgentEventThread
    belongs_to :event, Vibe.AgentEvent
    belongs_to :runbook, Vibe.AgentRunbook
    belongs_to :approved_by, Vibe.Accounts.User, foreign_key: :approved_by_user_id

    has_many :decision_actions, Vibe.AgentDecisionAction, foreign_key: :task_id

    timestamps()
  end

  def statuses, do: @statuses
  def action_modes, do: @action_modes
  def sources, do: @sources

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :agent_id,
      :thread_id,
      :event_id,
      :runbook_id,
      :approved_by_user_id,
      :chat_id,
      :requested_action,
      :rationale,
      :status,
      :decision_note,
      :decided_at,
      :action_mode,
      :expires_at,
      :message_id,
      :chosen_action_id,
      :source
    ])
    |> validate_required([:agent_id, :requested_action, :status, :chat_id])
    |> maybe_require_thread_and_event(attrs)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:action_mode, @action_modes)
    |> validate_inclusion(:source, @sources)
  end

  defp maybe_require_thread_and_event(changeset, attrs) do
    source = attrs[:source] || attrs["source"] || get_field(changeset, :source)

    if source == "runtime" do
      changeset
    else
      validate_required(changeset, [:thread_id, :event_id])
    end
  end
end
