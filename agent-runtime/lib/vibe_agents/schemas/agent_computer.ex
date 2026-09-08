defmodule VibeAgents.Schemas.AgentComputer do
  @moduledoc "One sandbox lease per agent (agent_id is unique — one computer per agent)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_computers" do
    field :agent_id, :binary_id
    field :sandbox_id, :string
    field :status, :string, default: "none"
    field :last_used_at, :utc_datetime
    field :image, :string

    timestamps()
  end

  def changeset(computer, attrs) do
    computer
    |> cast(attrs, [:agent_id, :sandbox_id, :status, :last_used_at, :image])
    |> validate_required([:agent_id, :status])
    |> unique_constraint(:agent_id)
  end
end
