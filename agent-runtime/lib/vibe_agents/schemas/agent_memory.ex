defmodule VibeAgents.Schemas.AgentMemory do
  @moduledoc "One remembered key/value fact for an agent, written by the `remember` tool."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_memories" do
    field :agent_id, :binary_id
    field :key, :string
    field :value, :string
    field :created_by_run_id, :binary_id

    timestamps()
  end

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [:agent_id, :key, :value, :created_by_run_id])
    |> validate_required([:agent_id, :key, :value])
    |> unique_constraint([:agent_id, :key])
  end
end
