defmodule Vibe.ConnectionGrant do
  use Ecto.Schema
  import Ecto.Changeset

  @grantee_types ~w[agent bridge_agent chat]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "connection_grants" do
    field :grantee_type, :string
    field :grantee_id, :string
    field :capabilities, {:array, :string}, default: []
    field :enabled, :boolean, default: true

    belongs_to :connection, Vibe.PlatformConnection

    timestamps()
  end

  def grantee_types, do: @grantee_types

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:connection_id, :grantee_type, :grantee_id, :capabilities, :enabled])
    |> validate_required([:connection_id, :grantee_type, :grantee_id])
    |> validate_inclusion(:grantee_type, @grantee_types)
    |> validate_length(:grantee_id, min: 1, max: 120)
    |> unique_constraint([:connection_id, :grantee_type, :grantee_id],
      name: :connection_grants_connection_grantee_index
    )
  end
end
