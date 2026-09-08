defmodule Vibe.AgentDecisionAction do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w[pending chosen superseded expired]
  @styles ~w[primary secondary destructive default]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_decision_actions" do
    field(:action_id, :string)
    field(:label, :string)
    field(:style, :string, default: "secondary")
    field(:confirm, :string)
    field(:token_hash, :string)
    field(:status, :string, default: "pending")
    field(:position, :integer, default: 0)
    field(:chosen_at, :utc_datetime)

    belongs_to(:task, Vibe.AgentApprovalTask)
    belongs_to(:chosen_by, Vibe.Accounts.User, foreign_key: :chosen_by_user_id)

    timestamps()
  end

  def statuses, do: @statuses
  def styles, do: @styles

  def changeset(action, attrs) do
    action
    |> cast(attrs, [
      :task_id,
      :action_id,
      :label,
      :style,
      :confirm,
      :token_hash,
      :status,
      :position,
      :chosen_by_user_id,
      :chosen_at
    ])
    |> validate_required([:task_id, :action_id, :label, :token_hash, :status, :position])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:style, @styles)
    |> unique_constraint(:token_hash)
    |> unique_constraint([:task_id, :action_id])
  end
end
