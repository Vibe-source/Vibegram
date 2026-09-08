defmodule VibeAgents.Schemas.OutboxEvent do
  @moduledoc "One RunEvent queued for delivery to the core, retried with backoff until acked."
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id

  schema "outbox_events" do
    field :run_id, :binary_id
    field :seq, :integer
    field :body, :map, default: %{}
    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime
    field :delivered_at, :utc_datetime

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:run_id, :seq, :body, :attempts, :next_attempt_at, :delivered_at])
    |> validate_required([:run_id, :seq, :body])
  end
end
