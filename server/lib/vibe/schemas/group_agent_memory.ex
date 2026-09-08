defmodule Vibe.Chat.GroupAgentMemory do
  @moduledoc """
  Schema for group agent conversation memory.
  Stores recent messages and a compacted summary for long-running context.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Vibe.Repo
  alias Vibe.RepoRLS

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_agent_memory" do
    field :chat_id, :string
    field :messages, {:array, :map}, default: []
    field :summary, :string
    field :total_messages_processed, :integer, default: 0
    field :last_compacted_at, :naive_datetime

    timestamps()
  end

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [:chat_id, :messages, :summary, :total_messages_processed, :last_compacted_at])
    |> validate_required([:chat_id])
    |> unique_constraint(:chat_id)
  end

  # ── CRUD ──

  def get_or_create(chat_id, opts \\ []) do
    acting_user_id = Keyword.get(opts, :acting_user_id)

    RepoRLS.with_user(acting_user_id, fn ->
      case Repo.one(from m in __MODULE__, where: m.chat_id == ^chat_id) do
        nil ->
          %__MODULE__{}
          |> changeset(%{chat_id: chat_id, messages: [], total_messages_processed: 0})
          |> Repo.insert()

        memory ->
          {:ok, memory}
      end
    end)
  end

  def append_message(chat_id, message, opts \\ []) do
    acting_user_id = Keyword.get(opts, :acting_user_id)

    RepoRLS.with_user(acting_user_id, fn ->
      case ensure_memory_row(chat_id, acting_user_id) do
        :ok ->
          Repo.transaction(fn ->
            memory =
              Repo.one!(
                from m in __MODULE__,
                  where: m.chat_id == ^chat_id,
                  lock: "FOR UPDATE"
              )

            msg =
              Map.merge(
                %{
                  "id" => Ecto.UUID.generate(),
                  "timestamp" => :os.system_time(:millisecond)
                },
                message
              )

            memory
            |> changeset(%{
              messages: memory.messages ++ [msg],
              total_messages_processed: memory.total_messages_processed + 1
            })
            |> Repo.update!()
          end)

        error ->
          error
      end
    end)
  end

  defp ensure_memory_row(chat_id, acting_user_id) do
    case get_or_create(chat_id, acting_user_id: acting_user_id) do
      {:ok, _memory} ->
        :ok

      {:error, %Ecto.Changeset{}} ->
        if Repo.exists?(from m in __MODULE__, where: m.chat_id == ^chat_id),
          do: :ok,
          else: {:error, :memory_unavailable}

      error ->
        error
    end
  end

  def update_after_compaction(memory, summary, remaining_messages, opts \\ []) do
    acting_user_id = Keyword.get(opts, :acting_user_id)

    RepoRLS.with_user(acting_user_id, fn ->
      memory
      |> changeset(%{
        messages: remaining_messages,
        summary: summary,
        last_compacted_at: NaiveDateTime.utc_now()
      })
      |> Repo.update()
    end)
  end

  def clear(chat_id, opts \\ []) do
    acting_user_id = Keyword.get(opts, :acting_user_id)

    RepoRLS.with_user(acting_user_id, fn ->
      case Repo.one(from m in __MODULE__, where: m.chat_id == ^chat_id) do
        nil ->
          {:ok, nil}

        memory ->
          memory
          |> changeset(%{
            messages: [],
            summary: nil,
            total_messages_processed: 0,
            last_compacted_at: nil
          })
          |> Repo.update()
      end
    end)
  end

  def delete_by_chat(chat_id, opts \\ []) do
    acting_user_id = Keyword.get(opts, :acting_user_id)

    RepoRLS.with_user(acting_user_id, fn ->
      from(m in __MODULE__, where: m.chat_id == ^chat_id)
      |> Repo.delete_all()
    end)
  end
end
