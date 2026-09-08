defmodule Vibe.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w[draft published disabled archived]
  @output_modes ~w[text media voice]
  @autonomy_modes ~w[draft_first manual safe_auto approval_required full_auto]
  @execution_modes ~w[embedded isolated]
  @model_providers Vibe.AI.ModelRegistry.provider_ids()

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agents" do
    field :status, :string, default: "draft"
    field :display_name, :string
    field :model_provider, :string, default: "anthropic"
    field :model_id, :string, default: "claude-sonnet-5"
    field :system_prompt, :string, default: ""
    field :prompt_variables, {:array, :map}, default: []
    field :persona, :string
    field :avatar_url, :string
    field :welcome_message, :string
    field :enabled_tools, {:array, :string}, default: []
    field :output_modes, {:array, :string}, default: ["text"]
    field :voice_provider, :string
    field :voice_profile, :string
    field :callback_url, :string
    field :autonomy_mode, :string, default: "safe_auto"
    field :default_destination_chat_id, :string
    field :event_types_enabled, {:array, :string}, default: []
    field :cost_budget_daily, :integer
    field :cost_budget_monthly, :integer
    field :approval_rules, :map, default: %{}
    field :runbook_ids, {:array, :binary_id}, default: []
    field :webhook_secret_hash, :string
    field :webhook_secret_encrypted, :string
    field :secret_hint, :string
    field :previous_secret_hash, :string
    field :previous_secret_expires_at, :utc_datetime
    field :published_at, :utc_datetime
    field :last_invoked_at, :utc_datetime
    field :execution_mode, :string, default: "embedded"
    field :admin_mode, :boolean, default: false, virtual: true

    belongs_to :owner, Vibe.Accounts.User, foreign_key: :owner_user_id
    belongs_to :agent_user, Vibe.Accounts.User, foreign_key: :agent_user_id

    timestamps()
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :owner_user_id,
      :agent_user_id,
      :status,
      :display_name,
      :model_provider,
      :model_id,
      :system_prompt,
      :prompt_variables,
      :persona,
      :avatar_url,
      :welcome_message,
      :enabled_tools,
      :output_modes,
      :voice_provider,
      :voice_profile,
      :callback_url,
      :autonomy_mode,
      :default_destination_chat_id,
      :event_types_enabled,
      :cost_budget_daily,
      :cost_budget_monthly,
      :approval_rules,
      :runbook_ids,
      :webhook_secret_hash,
      :webhook_secret_encrypted,
      :secret_hint,
      :previous_secret_hash,
      :previous_secret_expires_at,
      :published_at,
      :last_invoked_at,
      :execution_mode
    ])
    |> validate_required([
      :owner_user_id,
      :agent_user_id,
      :status,
      :display_name,
      :model_provider,
      :model_id,
      :webhook_secret_hash,
      :secret_hint
    ])
    |> validate_length(:display_name, min: 1, max: 80)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:model_provider, @model_providers)
    |> validate_model_selection()
    |> validate_inclusion(:autonomy_mode, @autonomy_modes)
    |> validate_inclusion(:execution_mode, @execution_modes)
    |> validate_change(:output_modes, fn :output_modes, modes ->
      invalid = Enum.reject(List.wrap(modes), &(&1 in @output_modes))
      if invalid == [], do: [], else: [output_modes: "contains invalid modes: #{Enum.join(invalid, ", ")}"]
    end)
    |> unique_constraint(:agent_user_id)
    |> check_constraint(:model_provider, name: :agents_model_provider_check)
  end

  def owner_changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :display_name,
      :model_provider,
      :model_id,
      :system_prompt,
      :prompt_variables,
      :persona,
      :avatar_url,
      :welcome_message,
      :enabled_tools,
      :output_modes,
      :voice_provider,
      :voice_profile,
      :callback_url,
      :autonomy_mode,
      :default_destination_chat_id,
      :event_types_enabled,
      :cost_budget_daily,
      :cost_budget_monthly,
      :approval_rules,
      :runbook_ids,
      :execution_mode
    ])
    |> validate_length(:display_name, min: 1, max: 80)
    |> validate_inclusion(:model_provider, @model_providers)
    |> validate_model_selection()
    |> validate_inclusion(:autonomy_mode, @autonomy_modes)
    |> validate_inclusion(:execution_mode, @execution_modes)
    |> validate_change(:output_modes, fn :output_modes, modes ->
      invalid = Enum.reject(List.wrap(modes), &(&1 in @output_modes))
      if invalid == [], do: [], else: [output_modes: "contains invalid modes: #{Enum.join(invalid, ", ")}"]
    end)
    |> check_constraint(:model_provider, name: :agents_model_provider_check)
  end

  defp validate_model_selection(changeset) do
    provider = get_field(changeset, :model_provider)
    model_id = get_field(changeset, :model_id)

    if Vibe.AI.ModelRegistry.valid_selection?(provider, model_id) do
      changeset
    else
      add_error(changeset, :model_id, "is not supported by the selected provider")
    end
  end
end
