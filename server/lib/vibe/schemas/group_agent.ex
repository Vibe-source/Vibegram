defmodule Vibe.Chat.GroupAgent do
  @moduledoc """
  Schema for AI agent configuration attached to a group or channel.
  Each group/channel can have at most one agent.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Vibe.Repo
  alias Vibe.RepoRLS

  @allowed_tools [
    "search_google", "analyze_image", "analyze_document", "create_document",
    "find_rows", "edit_rows", "delete_rows", "export_rows", "delete_document"
  ]
  @default_enabled_tools @allowed_tools

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_agents" do
    field :chat_id, :string
    field :enabled, :boolean, default: true
    field :name, :string, default: "Vibe AI"
    field :system_prompt, :string
    field :avatar_url, :string
    field :enabled_tools, {:array, :string}, default: @default_enabled_tools
    field :created_by, :binary_id

    timestamps()
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :chat_id,
      :enabled,
      :name,
      :system_prompt,
      :avatar_url,
      :enabled_tools,
      :created_by,
    ])
    |> validate_required([:chat_id, :system_prompt])
    |> validate_length(:name, max: 50)
    |> validate_length(:system_prompt, max: 4000)
    |> normalize_enabled_tools()
    |> validate_enabled_tools()
    |> unique_constraint(:chat_id)
  end

  defp normalize_enabled_tools(changeset) do
    raw_tools = get_field(changeset, :enabled_tools) || @default_enabled_tools

    normalized =
      raw_tools
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    final_tools = if normalized == [], do: @default_enabled_tools, else: normalized
    put_change(changeset, :enabled_tools, final_tools)
  end

  defp validate_enabled_tools(changeset) do
    tools = get_field(changeset, :enabled_tools) || []
    invalid_tools = Enum.reject(tools, &(&1 in @allowed_tools))

    if invalid_tools == [] do
      changeset
    else
      add_error(
        changeset,
        :enabled_tools,
        "contains unsupported tools: #{Enum.join(invalid_tools, ", ")}"
      )
    end
  end


  def create(attrs, opts \\ []) do
    acting_user_id = Keyword.get(opts, :acting_user_id) || attrs[:created_by] || attrs["created_by"]

    RepoRLS.with_user(acting_user_id, fn ->
      %__MODULE__{}
      |> changeset(attrs)
      |> Repo.insert()
    end)
  end

  def get_by_chat(chat_id, opts \\ []) do
    acting_user_id = Keyword.get(opts, :acting_user_id)

    RepoRLS.with_user(acting_user_id, fn ->
      Repo.one(from a in __MODULE__, where: a.chat_id == ^chat_id)
    end)
  end

  def get_enabled_by_chat(chat_id, opts \\ []) do
    acting_user_id = Keyword.get(opts, :acting_user_id)

    RepoRLS.with_user(acting_user_id, fn ->
      Repo.one(from a in __MODULE__, where: a.chat_id == ^chat_id and a.enabled == true)
    end)
  end

  def update(agent, attrs, opts \\ []) do
    acting_user_id = Keyword.get(opts, :acting_user_id) || attrs[:created_by] || attrs["created_by"]

    RepoRLS.with_user(acting_user_id, fn ->
      agent
      |> changeset(attrs)
      |> Repo.update()
    end)
  end

  def delete(agent, opts \\ []) do
    acting_user_id = Keyword.get(opts, :acting_user_id)

    RepoRLS.with_user(acting_user_id, fn ->
      Repo.delete(agent)
    end)
  end

  def delete_by_chat(chat_id, opts \\ []) do
    acting_user_id = Keyword.get(opts, :acting_user_id)

    RepoRLS.with_user(acting_user_id, fn ->
      from(a in __MODULE__, where: a.chat_id == ^chat_id)
      |> Repo.delete_all()
    end)
  end
end
