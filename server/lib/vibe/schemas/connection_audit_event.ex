defmodule Vibe.ConnectionAuditEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @actions ~w[
    authorize_started
    connected
    refreshed
    revoked
    grant_created
    grant_updated
    grant_revoked
    tool_call
    tool_denied
    error
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "connection_audit_events" do
    field :actor_type, :string
    field :actor_id, :string
    field :action, :string
    field :capability, :string
    field :detail, :map, default: %{}

    belongs_to :connection, Vibe.PlatformConnection
    belongs_to :user, Vibe.Accounts.User

    timestamps(updated_at: false)
  end

  def actions, do: @actions

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :connection_id,
      :user_id,
      :actor_type,
      :actor_id,
      :action,
      :capability,
      :detail
    ])
    |> validate_required([:actor_type, :action])
    |> validate_inclusion(:action, @actions)
  end
end
