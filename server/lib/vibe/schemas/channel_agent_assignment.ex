defmodule Vibe.Chat.ChannelAgentAssignment do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w[active disabled]
  @output_modes ~w[text media voice]
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "channel_agent_assignments" do
    belongs_to(:chat, Vibe.Chat.Room, type: :string)
    belongs_to(:agent, Vibe.Agent)
    field(:allowed_tools, {:array, :string}, default: [])
    field(:allowed_output_modes, {:array, :string}, default: [])
    field(:trigger_config, :map, default: %{})
    field(:permissions, :map, default: %{})
    field(:status, :string, default: "active")
    field(:next_trigger_at, :utc_datetime)
    field(:last_triggered_at, :utc_datetime)
    field(:last_trigger_status, :string)
    field(:last_trigger_error, :string)
    belongs_to(:creator, Vibe.Accounts.User, foreign_key: :created_by)

    timestamps()
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :chat_id,
      :agent_id,
      :allowed_tools,
      :allowed_output_modes,
      :trigger_config,
      :permissions,
      :status,
      :next_trigger_at,
      :last_triggered_at,
      :last_trigger_status,
      :last_trigger_error,
      :created_by
    ])
    |> validate_required([:chat_id, :agent_id, :status, :created_by])
    |> validate_inclusion(:status, @statuses)
    |> validate_change(:allowed_output_modes, fn :allowed_output_modes, modes ->
      invalid = Enum.reject(List.wrap(modes), &(&1 in @output_modes))

      if invalid == [],
        do: [],
        else: [allowed_output_modes: "contains invalid modes: #{Enum.join(invalid, ", ")}"]
    end)
    |> unique_constraint([:chat_id, :agent_id])
  end
end
