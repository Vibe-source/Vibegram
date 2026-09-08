defmodule Vibe.AgentConversation do
  @moduledoc """
  Schema for AI agent conversation history.
  Stores full conversation with messages for business audit trail.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Vibe.Repo
  require Logger

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_conversations" do
    field :user_id, :binary_id
    field :title, :string, default: "New Chat"
    field :messages, {:array, :map}, default: []
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc "Creates a changeset for an agent conversation"
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:user_id, :title, :messages, :metadata])
    |> validate_required([:user_id])
  end

  # CRUD Operations

  @doc "Create a new conversation for a user"
  def create(user_id, title \\ "New Chat") do
    %__MODULE__{}
    |> changeset(%{user_id: user_id, title: title, messages: []})
    |> Repo.insert()
  end

  @doc "Get a conversation by ID"
  def get(id) do
    Repo.get(__MODULE__, id)
  end

  @doc "Get a conversation by ID for a specific user (security check)"
  def get_for_user(id, user_id) do
    from(c in __MODULE__,
      where: c.id == ^id and c.user_id == ^user_id
    )
    |> Repo.one()
  end

  @doc "List all conversations for a user, most recent first"
  def list_for_user(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(c in __MODULE__,
      where: c.user_id == ^user_id,
      order_by: [desc: c.updated_at],
      limit: ^limit,
      select: %{
        id: c.id,
        title: c.title,
        message_count: fragment("jsonb_array_length(?)", c.messages),
        updated_at: c.updated_at,
        inserted_at: c.inserted_at
      }
    )
    |> Repo.all()
  end

  @doc "Add a message to a conversation"
  def add_message(conversation_id, message) do
    case get(conversation_id) do
      nil ->
        {:error, :not_found}

      conv ->
        msg = Map.merge(%{
          "id" => Ecto.UUID.generate(),
          "timestamp" => DateTime.utc_now() |> DateTime.to_unix(:millisecond)
        }, message)

        new_messages = conv.messages ++ [msg]

        title = if conv.title == "New Chat" and msg["role"] == "user" do
          String.slice(msg["content"] || "", 0..40)
        else
          conv.title
        end

        conv
        |> changeset(%{messages: new_messages, title: title})
        |> Repo.update()
    end
  end

  @doc "Update the last message (for streaming)"
  def update_last_message(conversation_id, updates) do
    case get(conversation_id) do
      nil ->
        {:error, :not_found}

      conv when length(conv.messages) > 0 ->
        messages = conv.messages
        last_msg = List.last(messages) |> Map.merge(updates)
        new_messages = List.replace_at(messages, -1, last_msg)

        conv
        |> changeset(%{messages: new_messages})
        |> Repo.update()

      _ ->
        {:error, :no_messages}
    end
  end

  @doc "Update the title of a conversation"
  def update_title(conversation_id, new_title) do
    case get(conversation_id) do
      nil -> {:error, :not_found}
      conv ->
        conv
        |> changeset(%{title: new_title})
        |> Repo.update()
    end
  end

  @doc "Delete a conversation"
  def delete(id, user_id) do
    case get_for_user(id, user_id) do
      nil -> {:error, :not_found}
      conv -> Repo.delete(conv)
    end
  end

  @doc "Truncate conversation history at a specific message ID (removes that message and all subsequent ones)"
  def truncate_history(id, user_id, message_id) do
    case get_for_user(id, user_id) do
      nil -> {:error, :not_found}
      conv ->
        index = Enum.find_index(conv.messages, fn m -> m["id"] == message_id end)

        if index do
          new_messages = Enum.slice(conv.messages, 0, index)

          conv
          |> changeset(%{messages: new_messages})
          |> Repo.update()
        else
          {:error, :message_not_found}
        end
    end
  end

  @doc "Clear all messages in a conversation but keep the conversation"
  def clear_messages(id, user_id) do
    case get_for_user(id, user_id) do
      nil -> {:error, :not_found}
      conv ->
        conv
        |> changeset(%{messages: []})
        |> Repo.update()
    end
  end

  @doc "Get full conversation with all messages"
  def get_full(id, user_id) do
    case get_for_user(id, user_id) do
      nil -> nil
      conv ->
        %{
          id: conv.id,
          title: conv.title,
          messages: conv.messages,
          created_at: naive_to_unix_ms(conv.inserted_at),
          updated_at: naive_to_unix_ms(conv.updated_at)
        }
    end
  end

  # Helper to convert NaiveDateTime to unix milliseconds
  defp naive_to_unix_ms(nil), do: 0
  defp naive_to_unix_ms(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end
  defp naive_to_unix_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)
end
