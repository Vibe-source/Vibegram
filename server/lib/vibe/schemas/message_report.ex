defmodule Vibe.Chat.MessageReport do
  use Ecto.Schema
  import Ecto.Changeset

  @reasons ~w(spam violence abuse sexual_content copyright personal_data other)
  @statuses ~w(pending reviewing resolved dismissed)
  @details_limit 1000

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "message_reports" do
    field(:reason, :string)
    field(:details, :string)
    field(:status, :string, default: "pending")
    field(:resolution, :string)
    field(:action, :string)
    field(:reviewed_at, :utc_datetime)
    field(:resolved_at, :utc_datetime)
    field(:chat_id, :string)
    field(:source_message_id, Ecto.UUID)

    belongs_to(:message, Vibe.Chat.Message, type: :binary_id)
    belongs_to(:reporter, Vibe.Accounts.User, type: :binary_id)
    belongs_to(:reported_user, Vibe.Accounts.User, type: :binary_id)
    belongs_to(:reviewer, Vibe.Accounts.User, type: :binary_id)

    timestamps()
  end

  def reasons, do: @reasons
  def details_limit, do: @details_limit

  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :message_id,
      :source_message_id,
      :chat_id,
      :reporter_id,
      :reported_user_id,
      :reason,
      :details,
      :status,
      :resolution,
      :action,
      :reviewer_id,
      :reviewed_at,
      :resolved_at
    ])
    |> validate_required([:message_id, :source_message_id, :chat_id, :reporter_id, :reason])
    |> validate_inclusion(:reason, @reasons)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:details, max: @details_limit)
  end
end
