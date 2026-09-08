defmodule Vibe.AgentRoutine do
  @moduledoc """
  A scheduled proactive run for an agent: send `prompt` into `chat_id` every
  `every_minutes`. See `Vibe.AgentRoutines` and `Vibe.AgentRoutineScheduler`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w[active paused disabled_failures]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_routines" do
    belongs_to :agent, Vibe.Agent
    field :owner_user_id, :binary_id
    field :chat_id, :string
    field :prompt, :string
    field :every_minutes, :integer
    field :status, :string, default: "active"
    field :next_trigger_at, :utc_datetime
    field :last_run_at, :utc_datetime
    field :last_status, :string
    field :last_error, :string
    field :consecutive_failures, :integer, default: 0

    timestamps()
  end

  def changeset(routine, attrs) do
    min_minutes = Application.get_env(:vibe, :agent_routine_min_minutes, 15)

    routine
    |> cast(attrs, [
      :agent_id,
      :owner_user_id,
      :chat_id,
      :prompt,
      :every_minutes,
      :status,
      :next_trigger_at,
      :last_run_at,
      :last_status,
      :last_error,
      :consecutive_failures
    ])
    |> validate_required([:agent_id, :owner_user_id, :chat_id, :prompt, :every_minutes])
    |> validate_length(:prompt, max: 4000)
    |> validate_number(:every_minutes,
      greater_than_or_equal_to: min_minutes,
      less_than_or_equal_to: 10080
    )
    |> validate_inclusion(:status, @statuses)
  end
end
