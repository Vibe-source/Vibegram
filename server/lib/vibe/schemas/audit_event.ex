defmodule Vibe.Schemas.AuditEvent do
  @moduledoc """
  One row per security-relevant action (login, logout, profile edit, device revoke, ...).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "audit_events" do
    field :actor_user_id, :binary_id
    field :action, :string
    field :target_type, :string
    field :target_id, :string
    field :ip, :string
    field :user_agent, :string
    field :metadata, :map, default: %{}

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :actor_user_id,
      :action,
      :target_type,
      :target_id,
      :ip,
      :user_agent,
      :metadata
    ])
    |> validate_required([:action])
    |> validate_length(:action, max: 255)
  end
end
