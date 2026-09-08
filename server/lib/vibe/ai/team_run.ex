defmodule Vibe.AI.TeamRun do
  @moduledoc """
  Durable control-plane state for one coordinated bridge team run.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "agent_team_runs" do
    field :chat_id, :string
    field :requester_user_id, :binary_id
    field :computer_id, :string
    field :reply_to_id, :string
    field :workers, {:array, :string}, default: []
    field :current_index, :integer, default: 0
    field :current_worker, :string
    field :mode, :string, default: "supervisor"
    field :lead_worker, :string
    field :worker_states, :map, default: %{}
    field :status, :string, default: "running"
    field :dispatch_ciphertext, :string
    field :bridge_metadata, :map, default: %{}
    field :last_error, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :id,
      :chat_id,
      :requester_user_id,
      :computer_id,
      :reply_to_id,
      :workers,
      :current_index,
      :current_worker,
      :mode,
      :lead_worker,
      :worker_states,
      :status,
      :dispatch_ciphertext,
      :bridge_metadata,
      :last_error
    ])
    |> validate_required([
      :id,
      :chat_id,
      :requester_user_id,
      :workers,
      :current_worker,
      :status,
      :dispatch_ciphertext
    ])
    |> validate_inclusion(:status, ["running", "completed", "failed", "cancelled"])
    |> validate_inclusion(:mode, ["supervisor", "sequential", "solo"])
    |> validate_number(:current_index, greater_than_or_equal_to: 0)
    |> unique_constraint(:id, name: :agent_team_runs_pkey)
  end
end
