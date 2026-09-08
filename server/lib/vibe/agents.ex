defmodule Vibe.Agents do
  import Ecto.Query, warn: false
  import Plug.Crypto, only: [secure_compare: 2]

  alias Vibe.Repo
  alias Vibe.Accounts
  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.AgentApprovalTask
  alias Vibe.AgentConversation
  alias Vibe.AgentDeliveryEvent
  alias Vibe.AgentEvent
  alias Vibe.AgentEventThread
  alias Vibe.AgentIntegration
  alias Vibe.AgentInvocation
  alias Vibe.AgentRun
  alias Vibe.AgentRunbook
  alias Vibe.AI.ModelRegistry
  alias Vibe.Chat.Participant
  alias Vibe.Chat.Room
  alias Vibe.Subscriptions

  @builder_kind "vibeagent_builder"
  @reserved_usernames ["vibeagent", "claude", "codex", "grok", "agy"]
  @default_output_modes ["text"]

  def default_output_modes, do: @default_output_modes

  def default_enabled_tools do
    Vibe.AI.ToolRegistry.default_tool_ids()
  end

  def agent_limit_for_user(user_id), do: Subscriptions.agent_limit_for_user(user_id)

  def quota_for_user(user_id) do
    used =
      if is_nil(user_id) do
        0
      else
        Repo.one(
          from a in Agent,
            where: a.owner_user_id == ^user_id and a.status != "archived",
            select: count(a.id)
        ) || 0
      end

    limit = agent_limit_for_user(user_id)
    %{used: used, limit: limit, remaining: max(limit - used, 0)}
  end

  def list_agents(nil), do: []

  def list_agents(owner_user_id) do
    Repo.all(
      from a in Agent,
        where: a.owner_user_id == ^owner_user_id and a.status != "archived",
        preload: [:agent_user],
        order_by: [desc: a.updated_at]
    )
  end

  def get_agent(id, owner_user_id \\ nil)

  def get_agent(id, nil) when is_binary(id) do
    with {:ok, agent_id} <- Ecto.UUID.cast(id) do
      Repo.one(from a in Agent, where: a.id == ^agent_id, preload: [:agent_user])
    else
      :error -> nil
    end
  end

  def get_agent(id, owner_user_id) when is_binary(id) do
    with {:ok, agent_id} <- Ecto.UUID.cast(id),
         {:ok, owner_id} <- Ecto.UUID.cast(owner_user_id) do
      Repo.one(
        from a in Agent,
          where: a.id == ^agent_id and a.owner_user_id == ^owner_id,
          preload: [:agent_user]
      )
    else
      :error -> nil
    end
  end

  def get_agent_by_shadow_user(user_id) when is_binary(user_id) do
    Repo.one(from a in Agent, where: a.agent_user_id == ^user_id, preload: [:agent_user])
  end

  def get_agent_by_username(username) when is_binary(username) do
    normalized = normalize_username(username)

    Repo.one(
      from a in Agent,
        join: u in User,
        on: u.id == a.agent_user_id,
        where: fragment("LOWER(?)", u.username) == ^normalized,
        preload: [agent_user: u]
    )
  end

  def get_invoke_target(identifier) when is_binary(identifier) do
    get_agent(identifier) || get_agent_by_username(identifier)
  end

  def create_agent(owner_user_id, attrs \\ %{}) do
    with {:ok, model_selection} <- ModelRegistry.resolve_selection(attrs),
         :ok <- ensure_quota(owner_user_id),
         {:ok, secret_tuple} <- generate_secret_tuple(),
         {:ok, shadow_user} <- create_shadow_user(owner_user_id, attrs),
         {:ok, agent} <-
           %Agent{}
           |> Agent.changeset(%{
             owner_user_id: owner_user_id,
             agent_user_id: shadow_user.id,
             status: "draft",
             display_name: display_name_from_attrs(attrs),
             model_provider: model_selection.provider,
             model_id: model_selection.model_id,
             system_prompt: string_attr(attrs, "system_prompt") || "",
             prompt_variables: Vibe.AI.PromptVariables.normalize(attrs["prompt_variables"] || attrs[:prompt_variables]),
             persona: string_attr(attrs, "persona"),
             avatar_url: string_attr(attrs, "avatar_url"),
             welcome_message: string_attr(attrs, "welcome_message"),
             enabled_tools: normalize_enabled_tools(attrs["enabled_tools"] || attrs[:enabled_tools]),
             output_modes: normalize_output_modes(attrs["output_modes"] || attrs[:output_modes]),
             voice_provider: string_attr(attrs, "voice_provider"),
             voice_profile: string_attr(attrs, "voice_profile") || "alloy",
             callback_url: normalize_callback_url(attrs["callback_url"] || attrs[:callback_url]),
             autonomy_mode: normalize_autonomy_mode(attrs["autonomy_mode"] || attrs[:autonomy_mode]),
             default_destination_chat_id: string_attr(attrs, "default_destination_chat_id"),
             event_types_enabled: normalize_optional_string_list(attrs["event_types_enabled"] || attrs[:event_types_enabled]),
             cost_budget_daily: integer_attr(attrs, "cost_budget_daily"),
             cost_budget_monthly: integer_attr(attrs, "cost_budget_monthly"),
             approval_rules: map_attr(attrs, "approval_rules", %{}),
             webhook_secret_hash: secret_tuple.hash,
             webhook_secret_encrypted: secret_tuple.encrypted,
             secret_hint: secret_tuple.hint
           })
           |> Repo.insert() do
      agent = ensure_default_destination_chat(agent)
      {:ok, Repo.preload(agent, :agent_user), secret_tuple.secret}
    end
  end

  defp ensure_default_destination_chat(%Agent{default_destination_chat_id: nil} = agent) do
    with {:ok, chat_id, _status} <-
           Vibe.Chat.ensure_dm_chat(agent.owner_user_id, agent.agent_user_id),
         {:ok, updated} <-
           agent
           |> Ecto.Changeset.change(default_destination_chat_id: chat_id)
           |> Repo.update() do
      updated
    else
      _ -> agent
    end
  end

  defp ensure_default_destination_chat(%Agent{} = agent), do: agent

  def update_agent(%Agent{} = agent, attrs, owner_user_id) do
    if agent.owner_user_id != owner_user_id do
      {:error, :forbidden}
    else
      with {:ok, model_selection} <-
             ModelRegistry.resolve_selection(attrs, %{
               provider: agent.model_provider,
               model_id: agent.model_id
             }) do
        Repo.transaction(fn ->
          maybe_update_shadow_user!(agent, attrs)

          updated =
            agent
            |> Agent.owner_changeset(%{
              display_name: display_name_from_attrs(attrs, agent.display_name),
              model_provider: model_selection.provider,
              model_id: model_selection.model_id,
              system_prompt: Map.get(attrs, "system_prompt", Map.get(attrs, :system_prompt, agent.system_prompt || "")),
              prompt_variables: update_prompt_variables(agent, attrs),
              persona: map_get(attrs, "persona", agent.persona),
              avatar_url: map_get(attrs, "avatar_url", agent.avatar_url),
              welcome_message: map_get(attrs, "welcome_message", agent.welcome_message),
              enabled_tools: normalize_enabled_tools(Map.get(attrs, "enabled_tools", Map.get(attrs, :enabled_tools, agent.enabled_tools))),
              output_modes: normalize_output_modes(Map.get(attrs, "output_modes", Map.get(attrs, :output_modes, agent.output_modes))),
              voice_provider: map_get(attrs, "voice_provider", agent.voice_provider),
              voice_profile: map_get(attrs, "voice_profile", agent.voice_profile),
              callback_url: normalize_callback_url(Map.get(attrs, "callback_url", Map.get(attrs, :callback_url, agent.callback_url))),
              autonomy_mode: normalize_autonomy_mode(Map.get(attrs, "autonomy_mode", Map.get(attrs, :autonomy_mode, agent.autonomy_mode))),
              default_destination_chat_id: string_or_existing(agent.default_destination_chat_id, attrs, "default_destination_chat_id"),
              event_types_enabled: normalize_optional_string_list(Map.get(attrs, "event_types_enabled", Map.get(attrs, :event_types_enabled, agent.event_types_enabled))),
              cost_budget_daily: integer_or_existing(agent.cost_budget_daily, attrs, "cost_budget_daily"),
              cost_budget_monthly: integer_or_existing(agent.cost_budget_monthly, attrs, "cost_budget_monthly"),
              approval_rules: map_or_existing(agent.approval_rules || %{}, attrs, "approval_rules"),
              execution_mode: map_get(attrs, "execution_mode", agent.execution_mode)
            })
            |> Repo.update!()

          updated
          |> Agent.changeset(%{status: normalize_status_update(updated, attrs)})
          |> Repo.update!()
        end)
        |> case do
          {:ok, updated} ->
            Vibe.Chat.JoinCache.invalidate_all()
            {:ok, Repo.preload(updated, :agent_user)}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  def publish_agent(%Agent{} = agent, owner_user_id) do
    if agent.owner_user_id != owner_user_id do
      {:error, :forbidden}
    else
      cond do
        String.trim(agent.system_prompt || "") == "" ->
          {:error, :missing_system_prompt}

        Enum.empty?(agent.output_modes || []) ->
          {:error, :missing_output_modes}

        "voice" in (agent.output_modes || []) and is_nil(System.get_env("OPENAI_API_KEY")) ->
          {:error, :voice_unavailable}

        true ->
          agent
          |> Agent.changeset(%{status: "published", published_at: DateTime.utc_now()})
          |> Repo.update()
          |> case do
            {:ok, updated} -> {:ok, Repo.preload(updated, :agent_user)}
            error -> error
          end
      end
    end
  end

  @max_secret_grace_hours 168

  @doc """
  Issues a new agent secret.
  """
  def rotate_secret(%Agent{} = agent, owner_user_id, opts \\ []) do
    if agent.owner_user_id != owner_user_id do
      {:error, :forbidden}
    else
      with {:ok, grace_hours} <- normalize_grace_hours(Keyword.get(opts, :grace_hours)),
           {:ok, secret_tuple} <- generate_secret_tuple(),
           {:ok, updated} <-
             agent
             |> Agent.changeset(
               Map.merge(
                 %{
                   webhook_secret_hash: secret_tuple.hash,
                   webhook_secret_encrypted: secret_tuple.encrypted,
                   secret_hint: secret_tuple.hint
                 },
                 previous_secret_attrs(agent, grace_hours)
               )
             )
             |> Repo.update() do
        {:ok, Repo.preload(updated, :agent_user), secret_tuple.secret}
      end
    end
  end

  defp previous_secret_attrs(_agent, nil),
    do: %{previous_secret_hash: nil, previous_secret_expires_at: nil}

  defp previous_secret_attrs(%Agent{webhook_secret_hash: nil}, _hours),
    do: %{previous_secret_hash: nil, previous_secret_expires_at: nil}

  defp previous_secret_attrs(%Agent{webhook_secret_hash: hash}, hours) do
    %{
      previous_secret_hash: hash,
      previous_secret_expires_at:
        DateTime.utc_now() |> DateTime.add(hours * 3600, :second) |> DateTime.truncate(:second)
    }
  end

  defp normalize_grace_hours(nil), do: {:ok, nil}
  defp normalize_grace_hours(0), do: {:ok, nil}

  defp normalize_grace_hours(hours) when is_integer(hours) and hours > 0,
    do: {:ok, min(hours, @max_secret_grace_hours)}

  defp normalize_grace_hours(hours) when is_binary(hours) do
    case Integer.parse(String.trim(hours)) do
      {parsed, ""} -> normalize_grace_hours(parsed)
      _ -> {:error, :invalid_grace_hours}
    end
  end

  defp normalize_grace_hours(_), do: {:error, :invalid_grace_hours}

  def archive_agent(%Agent{} = agent, owner_user_id) do
    if agent.owner_user_id != owner_user_id do
      {:error, :forbidden}
    else
      Repo.transaction(fn ->
        from(p in Participant, where: p.user_id == ^agent.agent_user_id)
        |> Repo.delete_all()

        agent
        |> Agent.changeset(%{status: "archived", callback_url: nil, last_invoked_at: agent.last_invoked_at})
        |> Repo.update!()
      end)
      |> case do
        {:ok, updated} -> {:ok, Repo.preload(updated, :agent_user)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def attached_chats(%Agent{} = agent) do
    Repo.all(
      from r in Room,
        join: agent_p in Participant,
        on: agent_p.chat_id == r.id,
        join: owner_p in Participant,
        on: owner_p.chat_id == r.id,
        where:
          agent_p.user_id == ^agent.agent_user_id and
            owner_p.user_id == ^agent.owner_user_id and
            (is_nil(owner_p.deleted) or owner_p.deleted == false),
        select: %{
          chatId: r.id,
          type: r.type,
          name: r.name,
          avatarUrl: r.avatar_url
        }
    )
  end

  def published_agent_user?(user_id) when is_binary(user_id) do
    match?(%Agent{status: "published"}, get_agent_by_shadow_user(user_id))
  end

  def verify_secret(%Agent{} = agent, secret) when is_binary(secret) do
    expected = hash_secret(secret)

    secure_compare(expected, agent.webhook_secret_hash || "") or
      previous_secret_valid?(agent, expected)
  end

  def verify_secret(_agent, _secret), do: false

  defp previous_secret_valid?(%Agent{previous_secret_hash: hash} = agent, expected)
       when is_binary(hash) and hash != "" do
    case agent.previous_secret_expires_at do
      %DateTime{} = expires_at ->
        DateTime.compare(DateTime.utc_now(), expires_at) == :lt and
          secure_compare(expected, hash)

      _ ->
        false
    end
  end

  defp previous_secret_valid?(_agent, _expected), do: false

  defp previous_secret_window(%Agent{previous_secret_hash: hash} = agent)
       when is_binary(hash) and hash != "" do
    case agent.previous_secret_expires_at do
      %DateTime{} = expires_at ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt, do: expires_at, else: nil

      _ ->
        nil
    end
  end

  defp previous_secret_window(_agent), do: nil

  def callback_signing_secret(%Agent{webhook_secret_encrypted: encrypted}) when is_binary(encrypted) do
    decrypt_secret(encrypted)
  end

  def callback_signing_secret(_agent), do: {:error, :missing_encrypted_secret}

  def integration_secret(%AgentIntegration{secret_encrypted: encrypted}) when is_binary(encrypted) do
    decrypt_secret(encrypted)
  end

  def integration_secret(_integration), do: {:error, :missing_encrypted_secret}

  def record_invocation(%Agent{} = agent, attrs) do
    result =
      %AgentInvocation{}
      |> AgentInvocation.changeset(Map.put(attrs, :agent_id, agent.id))
      |> Repo.insert()

    case result do
      {:ok, invocation} ->
        _ =
          agent
          |> Agent.changeset(%{last_invoked_at: DateTime.utc_now()})
          |> Repo.update()

        {:ok, invocation}

      {:error, %Ecto.Changeset{} = changeset} ->
        if event_id_conflict?(changeset) do
          event_id = Map.get(attrs, :event_id) || Map.get(attrs, "event_id")

          Repo.one(
            from i in AgentInvocation,
              where: i.agent_id == ^agent.id and i.event_id == ^event_id,
              limit: 1
          )
          |> case do
            nil -> result
            invocation -> {:ok, invocation}
          end
        else
          result
        end

      _ ->
        result
    end
  end

  def list_delivery_data(%Agent{} = agent) do
    invocations =
      Repo.all(
        from i in AgentInvocation,
          where: i.agent_id == ^agent.id,
          order_by: [desc: i.inserted_at],
          limit: 50
      )
      |> Enum.map(fn invocation ->
        %{
          id: invocation.id,
          source: invocation.source,
          eventId: invocation.event_id,
          vibeChatId: invocation.vibe_chat_id,
          externalUserId: invocation.external_user_id,
          requestPayload: invocation.request_payload,
          responsePayload: invocation.response_payload,
          status: invocation.status,
          error: invocation.error,
          insertedAt: invocation.inserted_at
        }
      end)

    deliveries =
      Repo.all(
        from d in AgentDeliveryEvent,
          where: d.agent_id == ^agent.id,
          order_by: [desc: d.inserted_at],
          limit: 50
      )
      |> Enum.map(fn delivery ->
        %{
          id: delivery.id,
          invocationId: delivery.invocation_id,
          eventType: delivery.event_type,
          targetUrl: delivery.target_url,
          requestBody: delivery.request_body,
          responseCode: delivery.response_code,
          status: delivery.status,
          attemptCount: delivery.attempt_count,
          lastError: delivery.last_error,
          insertedAt: delivery.inserted_at
        }
      end)

    %{invocations: invocations, deliveries: deliveries}
  end

  def create_delivery_event(%Agent{} = agent, %AgentInvocation{} = invocation, event_type, body) do
    target_url = String.trim(agent.callback_url || "")

    cond do
      target_url == "" ->
        {:error, :missing_callback}

      match?({:error, _}, Vibe.Net.SafeURL.validate(target_url)) ->
        {:error, :invalid_callback_url}

      true ->
        %AgentDeliveryEvent{}
        |> AgentDeliveryEvent.changeset(%{
          agent_id: agent.id,
          invocation_id: invocation.id,
          event_type: event_type,
          target_url: target_url,
          request_body: body,
          status: "pending",
          attempt_count: 0
        })
        |> Repo.insert()
    end
  end

  def due_delivery_events(limit \\ 50) do
    Repo.all(
      from d in AgentDeliveryEvent,
        where: d.status in ["pending", "retrying"],
        order_by: [asc: d.inserted_at],
        limit: ^limit,
        preload: [:agent, :invocation]
    )
  end

  def update_delivery_event(%AgentDeliveryEvent{} = event, attrs) do
    event
    |> AgentDeliveryEvent.changeset(attrs)
    |> Repo.update()
  end

  def list_integrations(%Agent{} = agent) do
    Repo.all(
      from i in AgentIntegration,
        where: i.agent_id == ^agent.id,
        order_by: [asc: i.inserted_at]
    )
  end

  def get_integration(%Agent{} = agent, integration_id) when is_binary(integration_id) do
    Repo.one(
      from i in AgentIntegration,
        where: i.agent_id == ^agent.id and i.id == ^integration_id
    )
  end

  def find_integration_by_secret(%Agent{} = agent, secret) when is_binary(secret) do
    list_integrations(agent)
    |> Enum.find(&secure_compare(hash_secret(secret), &1.secret_hash || ""))
  end

  def find_integration_by_secret(_agent, _secret), do: nil

  def create_integration(%Agent{} = agent, attrs, owner_user_id) do
    if agent.owner_user_id != owner_user_id do
      {:error, :forbidden}
    else
      Repo.transaction(fn ->
        {:ok, secret_tuple} = generate_secret_tuple()

        integration =
          %AgentIntegration{}
          |> AgentIntegration.changeset(%{
            agent_id: agent.id,
            name: string_attr(attrs, "name") || build_default_integration_name(attrs),
            source_type: string_attr(attrs, "source_type") || "custom",
            default_destination_chat_id:
              string_attr(attrs, "default_destination_chat_id") || agent.default_destination_chat_id,
            autonomy_mode:
              normalize_autonomy_mode(
                Map.get(attrs, "autonomy_mode", Map.get(attrs, :autonomy_mode, agent.autonomy_mode))
              ),
            event_types_enabled:
              normalize_optional_string_list(
                Map.get(attrs, "event_types_enabled", Map.get(attrs, :event_types_enabled, []))
              ),
            routing_rules: map_attr(attrs, "routing_rules", %{}),
            approval_rules: map_attr(attrs, "approval_rules", agent.approval_rules || %{}),
            cost_budget_daily:
              integer_attr(attrs, "cost_budget_daily") || agent.cost_budget_daily,
            cost_budget_monthly:
              integer_attr(attrs, "cost_budget_monthly") || agent.cost_budget_monthly,
            enabled: boolean_attr(attrs, "enabled", true),
            secret_hash: secret_tuple.hash,
            secret_encrypted: secret_tuple.encrypted,
            secret_hint: secret_tuple.hint
          })
          |> Repo.insert!()

        sync_runbooks_for_integration!(agent, integration, attrs)
        refresh_agent_runbook_ids!(agent.id)

        {integration, secret_tuple.secret}
      end)
      |> case do
        {:ok, {integration, secret}} -> {:ok, integration, secret}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def update_integration(%AgentIntegration{} = integration, attrs, owner_user_id) do
    agent = get_agent(integration.agent_id, owner_user_id)

    if is_nil(agent) do
      {:error, :forbidden}
    else
      Repo.transaction(fn ->
        updated =
          integration
          |> AgentIntegration.changeset(%{
            name: string_or_existing(integration.name, attrs, "name"),
            source_type: string_or_existing(integration.source_type, attrs, "source_type"),
            default_destination_chat_id:
              string_or_existing(integration.default_destination_chat_id, attrs, "default_destination_chat_id"),
            autonomy_mode:
              normalize_autonomy_mode(
                Map.get(attrs, "autonomy_mode", Map.get(attrs, :autonomy_mode, integration.autonomy_mode))
              ),
            event_types_enabled:
              normalize_optional_string_list(
                Map.get(attrs, "event_types_enabled", Map.get(attrs, :event_types_enabled, integration.event_types_enabled))
              ),
            routing_rules: map_or_existing(integration.routing_rules || %{}, attrs, "routing_rules"),
            approval_rules: map_or_existing(integration.approval_rules || %{}, attrs, "approval_rules"),
            cost_budget_daily: integer_or_existing(integration.cost_budget_daily, attrs, "cost_budget_daily"),
            cost_budget_monthly: integer_or_existing(integration.cost_budget_monthly, attrs, "cost_budget_monthly"),
            enabled: boolean_or_existing(integration.enabled, attrs, "enabled")
          })
          |> Repo.update!()

        sync_runbooks_for_integration!(agent, updated, attrs)
        refresh_agent_runbook_ids!(agent.id)

        updated
      end)
      |> case do
        {:ok, updated} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def list_threads(%Agent{} = agent) do
    Repo.all(
      from t in AgentEventThread,
        where: t.agent_id == ^agent.id,
        order_by: [desc: t.latest_event_at, desc: t.updated_at]
    )
  end

  def list_events(%Agent{} = agent, opts \\ []) do
    limit =
      opts
      |> Keyword.get(:limit, 200)
      |> max(1)
      |> min(500)

    offset =
      opts
      |> Keyword.get(:offset, 0)
      |> max(0)

    base = from e in AgentEvent, where: e.agent_id == ^agent.id

    events =
      base
      |> order_by([e], desc: e.occurred_at, desc: e.inserted_at, desc: e.id)
      |> limit(^limit)
      |> offset(^offset)
      |> preload([:thread])
      |> Repo.all()

    {events, Repo.aggregate(base, :count, :id)}
  end

  def get_thread(%Agent{} = agent, thread_id) when is_binary(thread_id) do
    Repo.one(
      from t in AgentEventThread,
        where: t.agent_id == ^agent.id and t.id == ^thread_id,
        preload: [
          events: ^from(e in AgentEvent, order_by: [asc: e.occurred_at, asc: e.inserted_at]),
          approval_tasks:
            ^from(a in AgentApprovalTask, order_by: [desc: a.inserted_at], preload: [:approved_by]),
          integration: [],
          root_message: []
        ]
    )
  end

  def get_approval_task(%Agent{} = agent, task_id) when is_binary(task_id) do
    Repo.one(
      from t in AgentApprovalTask,
        where: t.agent_id == ^agent.id and t.id == ^task_id,
        preload: [:event, :thread, :runbook]
    )
  end

  def approve_task(%Agent{} = agent, task_id, owner_user_id, note \\ nil) do
    if agent.owner_user_id != owner_user_id do
      {:error, :forbidden}
    else
      case get_approval_task(agent, task_id) do
        nil ->
          {:error, :not_found}

        %AgentApprovalTask{status: status} when status != "pending" ->
          {:error, :already_decided}

        %AgentApprovalTask{} = task ->
          task
          |> AgentApprovalTask.changeset(%{
            status: "approved",
            approved_by_user_id: owner_user_id,
            decision_note: normalize_optional_string(note),
            decided_at: DateTime.utc_now()
          })
          |> Repo.update()
      end
    end
  end

  def reject_task(%Agent{} = agent, task_id, owner_user_id, note \\ nil) do
    if agent.owner_user_id != owner_user_id do
      {:error, :forbidden}
    else
      case get_approval_task(agent, task_id) do
        nil ->
          {:error, :not_found}

        %AgentApprovalTask{status: status} when status != "pending" ->
          {:error, :already_decided}

        %AgentApprovalTask{} = task ->
          task
          |> AgentApprovalTask.changeset(%{
            status: "rejected",
            approved_by_user_id: owner_user_id,
            decision_note: normalize_optional_string(note),
            decided_at: DateTime.utc_now()
          })
          |> Repo.update()
      end
    end
  end

  def get_or_create_builder_session(user_id) do
    query =
      from c in AgentConversation,
        where:
          c.user_id == ^user_id and
            fragment("?->>'kind' = ?", c.metadata, ^@builder_kind),
        order_by: [desc: c.updated_at],
        limit: 1

    case Repo.one(query) do
      nil ->
        AgentConversation.create(user_id, "Vibe Agent Builder")
        |> case do
          {:ok, conv} ->
            conv
            |> AgentConversation.changeset(%{metadata: %{"kind" => @builder_kind, "draft_state" => %{}}})
            |> Repo.update()

          error ->
            error
        end

      conv ->
        {:ok, conv}
    end
  end

  def update_builder_session(%AgentConversation{} = conversation, attrs) do
    conversation
    |> AgentConversation.changeset(attrs)
    |> Repo.update()
  end

  def agent_payload(%Agent{} = agent, opts \\ []) do
    quota = Keyword.get(opts, :quota)
    agent = Repo.preload(agent, :agent_user)

    payload = %{
      id: agent.id,
      userId: agent.agent_user_id,
      username: agent.agent_user && agent.agent_user.username,
      publicLink: Vibe.Links.agent_url(agent.agent_user && agent.agent_user.username),
      displayName: agent.display_name,
      status: agent.status,
      modelProvider: agent.model_provider,
      modelId: agent.model_id,
      systemPrompt: agent.system_prompt,
      promptVariables: Vibe.AI.PromptVariables.definitions(agent),
      persona: agent.persona,
      avatarUrl: agent.avatar_url,
      welcomeMessage: agent.welcome_message,
      enabledTools: agent.enabled_tools || [],
      outputModes: agent.output_modes || [],
      autonomyMode: agent.autonomy_mode,
      executionMode: agent.execution_mode,
      defaultDestinationChatId: agent.default_destination_chat_id,
      eventTypesEnabled: agent.event_types_enabled || [],
      costBudgetDaily: agent.cost_budget_daily,
      costBudgetMonthly: agent.cost_budget_monthly,
      approvalRules: agent.approval_rules || %{},
      runbookIds: agent.runbook_ids || [],
      voiceProvider: agent.voice_provider,
      voiceProfile: agent.voice_profile,
      callbackUrl: agent.callback_url,
      secretHint: agent.secret_hint,
      previousSecretExpiresAt: previous_secret_window(agent),
      publishedAt: agent.published_at,
      lastInvokedAt: agent.last_invoked_at,
      attachedChats: attached_chats(agent),
      integrations: Enum.map(list_integrations(agent), &integration_payload/1)
    }

    if quota, do: Map.put(payload, :quota, quota), else: payload
  end

  def incoming_chat_enabled?(%Agent{} = agent) do
    chat_rules =
      get_in(agent.approval_rules || %{}, ["chat_input"])
      || get_in(agent.approval_rules || %{}, [:chat_input])
      || %{}

    case chat_rules["enabled"] || chat_rules[:enabled] do
      false -> false
      "false" -> false
      "0" -> false
      0 -> false
      _ -> true
    end
  end

  def agent_id_for_user(user_id) when is_binary(user_id) do
    case get_agent_by_shadow_user(user_id) do
      %Agent{id: id} -> id
      _ -> nil
    end
  end

  def visible_to_invite?(%Agent{status: "published"}), do: true
  def visible_to_invite?(_), do: false

  def builder_kind, do: @builder_kind

  def reserved_username?(username) do
    normalize_username(username) in @reserved_usernames
  end

  def normalize_username(username) when is_binary(username) do
    username
    |> String.trim()
    |> String.trim_leading("@")
    |> String.downcase()
  end

  def normalize_username(_), do: ""

  @doc """
  Checks whether `username` can be assigned to the given agent (or, when `agent` is nil, to a
  brand-new agent).
  """
  def username_availability(username, agent \\ nil)

  def username_availability(username, %Agent{} = agent) do
    agent = if Ecto.assoc_loaded?(agent.agent_user), do: agent, else: Repo.preload(agent, :agent_user)
    current = agent.agent_user && normalize_username(agent.agent_user.username)
    normalized = normalize_username(username)

    cond do
      agent.status != "draft" and normalized != current ->
        {:error, :username_locked_after_publish}

      not is_nil(current) and normalized == current ->
        {:ok, normalized}

      true ->
        validate_username_string(normalized)
    end
  end

  def username_availability(username, nil) do
    validate_username_string(normalize_username(username))
  end

  defp validate_username_string(normalized) do
    cond do
      normalized == "" -> {:error, :invalid_username}
      reserved_username?(normalized) or Accounts.reserved_username?(normalized) -> {:error, :reserved_username}
      not Regex.match?(~r/^[a-z0-9_]+$/, normalized) -> {:error, :invalid_username}
      String.length(normalized) < 3 or String.length(normalized) > 30 -> {:error, :invalid_username}
      Accounts.username_exists?(normalized) -> {:error, :username_taken}
      true -> {:ok, normalized}
    end
  end

  defp update_prompt_variables(%Agent{} = agent, attrs) do
    cond do
      Map.has_key?(attrs, "prompt_variables") ->
        Vibe.AI.PromptVariables.normalize(attrs["prompt_variables"])

      Map.has_key?(attrs, :prompt_variables) ->
        Vibe.AI.PromptVariables.normalize(attrs[:prompt_variables])

      true ->
        agent.prompt_variables || []
    end
  end

  def normalize_enabled_tools(raw_tools) do
    raw_tools
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.filter(&(&1 in Vibe.AI.ToolRegistry.tool_ids()))
    |> Enum.uniq()
    |> case do
      [] -> default_enabled_tools()
      tools -> tools
    end
  end

  def normalize_output_modes(raw_modes) do
    raw_modes
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.filter(&(&1 in ~w[text media voice]))
    |> Enum.uniq()
    |> case do
      [] -> @default_output_modes
      modes -> modes
    end
  end

  def normalize_autonomy_mode(value) do
    case normalize_optional_string(value) do
      "manual" -> "manual"
      "draft_first" -> "draft_first"
      "approval_required" -> "approval_required"
      "full_auto" -> "full_auto"
      "safe_auto" -> "safe_auto"
      _ -> "safe_auto"
    end
  end

  def integration_payload(%AgentIntegration{} = integration, opts \\ []) do
    latest_secret = Keyword.get(opts, :latest_secret)

    %{
      id: integration.id,
      agentId: integration.agent_id,
      name: integration.name,
      sourceType: integration.source_type,
      defaultDestinationChatId: integration.default_destination_chat_id,
      autonomyMode: integration.autonomy_mode,
      eventTypesEnabled: integration.event_types_enabled || [],
      routingRules: integration.routing_rules || %{},
      approvalRules: integration.approval_rules || %{},
      costBudgetDaily: integration.cost_budget_daily,
      costBudgetMonthly: integration.cost_budget_monthly,
      enabled: integration.enabled,
      secretHint: integration.secret_hint,
      latestSecret: latest_secret,
      lastEventAt: integration.last_event_at,
      runbooks: list_runbooks_for_integration(integration)
    }
  end

  def thread_payload(%AgentEventThread{} = thread, opts \\ []) do
    include_details = Keyword.get(opts, :details, false)

    base = %{
      id: thread.id,
      agentId: thread.agent_id,
      integrationId: thread.integration_id,
      chatId: thread.chat_id,
      source: thread.source,
      threadKey: thread.thread_key,
      title: thread.title,
      summary: thread.summary,
      currentState: thread.current_state || %{},
      priority: thread.priority,
      status: thread.status,
      lastDecision: thread.last_decision,
      latestEventAt: thread.latest_event_at,
      rootMessageId: thread.root_message_id
    }

    if include_details do
      Map.merge(base, %{
        events:
          Enum.map(thread.events || [], fn event ->
            %{
              id: event.id,
              eventId: event.event_id,
              eventType: event.event_type,
              source: event.source,
              title: event.title,
              text: event.text,
              attachments: normalize_attachments_payload(event.attachments),
              payload: event.payload || %{},
              occurredAt: event.occurred_at,
              status: event.status,
              decision: event.decision,
              decisionReason: event.decision_reason,
              messageId: event.message_id
            }
          end),
        approvalTasks: Enum.map(thread.approval_tasks || [], &approval_task_payload/1)
      })
    else
      base
    end
  end

  def event_payload(%AgentEvent{} = event) do
    thread =
      case event.thread do
        %AgentEventThread{} = value -> value
        _ -> nil
      end

    %{
      id: event.id,
      eventId: event.event_id,
      eventType: event.event_type,
      source: event.source,
      title: event.title,
      text: event.text,
      attachments: normalize_attachments_payload(event.attachments),
      payload: event.payload || %{},
      occurredAt: event.occurred_at,
      status: event.status,
      decision: event.decision,
      decisionReason: event.decision_reason,
      messageId: event.message_id,
      threadId: event.thread_id,
      threadKey: thread && thread.thread_key,
      threadTitle: thread && thread.title,
      priority: (thread && thread.priority) || "normal"
    }
  end

  def approval_task_payload(%AgentApprovalTask{} = task) do
    %{
      id: task.id,
      agentId: task.agent_id,
      threadId: task.thread_id,
      eventId: task.event_id,
      runbookId: task.runbook_id,
      chatId: task.chat_id,
      requestedAction: task.requested_action || %{},
      rationale: task.rationale,
      status: task.status,
      decisionNote: task.decision_note,
      decidedAt: task.decided_at,
      approvedByUserId: task.approved_by_user_id,
      actionMode: task.action_mode || "single",
      expiresAt: task.expires_at,
      messageId: task.message_id,
      chosenActionId: task.chosen_action_id,
      source: task.source || "runbook"
    }
  end

  def run_payload(%AgentRun{} = run) do
    %{
      id: run.id,
      agentId: run.agent_id,
      integrationId: run.integration_id,
      threadId: run.thread_id,
      eventId: run.event_id,
      runbookId: run.runbook_id,
      trigger: run.trigger,
      mode: run.mode,
      model: run.model,
      promptVersion: run.prompt_version,
      decision: run.decision,
      auditSummary: run.audit_summary,
      toolCalls: run.tool_calls || %{},
      result: run.result || %{},
      status: run.status,
      error: run.error,
      costUsd: run.cost_usd,
      promptTokens: run.prompt_tokens,
      completionTokens: run.completion_tokens,
      insertedAt: run.inserted_at
    }
  end

  defp ensure_quota(owner_user_id) do
    quota = quota_for_user(owner_user_id)
    if quota.used >= quota.limit, do: {:error, :quota_exceeded}, else: :ok
  end

  defp create_shadow_user(_owner_user_id, attrs) do
    display_name = display_name_from_attrs(attrs)

    with {:ok, username} <- resolve_shadow_username(display_name, attrs) do
      insert_shadow_user(display_name, username, attrs)
    end
  end

  defp resolve_shadow_username(display_name, attrs) do
    case Map.get(attrs, "username") || Map.get(attrs, :username) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          derive_username(display_name)
        else
          username_availability(value, nil)
        end

      _ ->
        derive_username(display_name)
    end
  end

  defp derive_username(display_name) do
    case username_base(display_name) do
      nil -> {:error, :invalid_username}
      base -> username_availability(base, nil)
    end
  end

  defp insert_shadow_user(display_name, username, attrs) do
    user_id = UUID.uuid4()

    Accounts.create_user(%{
      "id" => user_id,
      "username" => username,
      "name" => display_name,
      "password_hash" => "agent:#{user_id}",
      "device_id" => "agent:#{user_id}",
      "public_key" => "agent",
      "encrypted_private_key" => "agent",
      "identity_key" => "agent",
      "secure_id" => "agent:#{user_id}",
      "profile_image" => string_attr(attrs, "avatar_url"),
      "is_agent" => true
    })
  end

  defp maybe_update_shadow_user!(%Agent{} = agent, attrs) do
    user = agent.agent_user || Repo.preload(agent, :agent_user).agent_user

    update_attrs =
      %{}
      |> maybe_put("name", display_name_from_attrs(attrs, user.name || agent.display_name))
      |> maybe_put("profile_image", string_attr(attrs, "avatar_url"))

    update_attrs =
      case Map.get(attrs, "username") || Map.get(attrs, :username) do
        nil ->
          update_attrs

        value ->
          if agent.status != "draft" do
            Repo.rollback(:username_locked_after_publish)
          else
            username = ensure_valid_username!(value)
            Map.put(update_attrs, "username", username)
          end
      end

    if map_size(update_attrs) > 0 do
      case Accounts.update_user(user, update_attrs) do
        {:ok, _updated_user} -> :ok
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end
  end

  defp ensure_valid_username!(username) do
    normalized = normalize_username(username)

    cond do
      normalized == "" -> Repo.rollback(:invalid_username)
      reserved_username?(normalized) or Accounts.reserved_username?(normalized) -> Repo.rollback(:reserved_username)
      Accounts.username_exists?(normalized) -> Repo.rollback(:username_taken)
      not Regex.match?(~r/^[a-z0-9_]+$/, normalized) -> Repo.rollback(:invalid_username)
      String.length(normalized) < 3 or String.length(normalized) > 30 -> Repo.rollback(:invalid_username)
      true -> normalized
    end
  end

  @doc """
  Clean handle candidates derived from a display name, filtered to the ones that are actually
  free.
  """
  def suggest_usernames(display_name, opts \\ []) do
    limit = Keyword.get(opts, :limit, 4)
    base = username_base(display_name) || "agent"

    ([base] ++
       Enum.map(~w[ai bot hq agent live], &"#{base}_#{&1}") ++
       Enum.map(~w[ask my the], &"#{&1}_#{base}"))
    |> Enum.uniq()
    |> Enum.reduce_while([], fn candidate, acc ->
      cond do
        length(acc) >= limit -> {:halt, acc}
        match?({:ok, _}, username_availability(candidate, nil)) -> {:cont, acc ++ [candidate]}
        true -> {:cont, acc}
      end
    end)
  end

  @doc false
  def username_base(display_name) do
    display_name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
    |> String.slice(0, 24)
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp generate_secret_tuple do
    secret = "vas_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    with {:ok, encrypted} <- encrypt_secret(secret) do
      {:ok,
       %{
         secret: secret,
         hash: hash_secret(secret),
         encrypted: encrypted,
         hint: String.slice(secret, -6, 6)
       }}
    end
  end

  defp hash_secret(secret) do
    :crypto.hash(:sha256, secret)
    |> Base.encode16(case: :lower)
  end

  defp encrypt_secret(secret) when is_binary(secret) do
    iv = :crypto.strong_rand_bytes(12)
    key = callback_secret_encryption_key()

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        iv,
        secret,
        "",
        16,
        true
      )

    {:ok,
     Enum.join(
       [
         "ags1",
         Base.url_encode64(iv, padding: false),
         Base.url_encode64(ciphertext, padding: false),
         Base.url_encode64(tag, padding: false)
       ],
       "."
     )}
  rescue
    error ->
      {:error, {:secret_encryption_failed, error}}
  end

  defp decrypt_secret(ciphertext) when is_binary(ciphertext) do
    with ["ags1", iv_b64, data_b64, tag_b64] <- String.split(ciphertext, ".", parts: 4),
         {:ok, iv} <- Base.url_decode64(iv_b64, padding: false),
         {:ok, encrypted} <- Base.url_decode64(data_b64, padding: false),
         {:ok, tag} <- Base.url_decode64(tag_b64, padding: false) do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             callback_secret_encryption_key(),
             iv,
             encrypted,
             "",
             tag,
             false
           ) do
        :error -> {:error, :secret_decryption_failed}
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
      end
    else
      _ -> {:error, :secret_decryption_failed}
    end
  rescue
    _ -> {:error, :secret_decryption_failed}
  end

  defp callback_secret_encryption_key do
    seed =
      System.get_env("VIBE_AGENT_SECRET_ENCRYPTION_KEY")
      || System.get_env("VIBE_HMAC_SECRET")
      || System.get_env("SECRET_KEY_BASE")
      || Application.get_env(:vibe, VibeWeb.Endpoint, [])[:secret_key_base]
      || raise "Missing callback secret encryption seed"

    :crypto.hash(:sha256, seed)
  end

  defp map_get(map, key, fallback) do
    key
    |> key_variants()
    |> Enum.find_value(fallback, fn variant ->
      cond do
        Map.has_key?(map, variant) ->
          Map.get(map, variant)

        is_binary(variant) ->
          case safe_existing_atom(variant) do
            nil ->
              nil

            atom_key ->
              if Map.has_key?(map, atom_key), do: Map.get(map, atom_key), else: nil
          end

        true ->
          nil
      end
    end)
  end

  defp string_attr(map, key) do
    case map_get(map, key, nil) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp integer_attr(map, key) do
    case map_get(map, key, nil) do
      value when is_integer(value) -> value
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, _} -> parsed
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp boolean_attr(map, key, fallback \\ nil) do
    case map_get(map, key, fallback) do
      value when value in [true, false] -> value
      value when value in ["true", "1", 1] -> true
      value when value in ["false", "0", 0] -> false
      _ -> fallback
    end
  end

  defp map_attr(map, key, fallback) do
    case map_get(map, key, fallback) do
      value when is_map(value) -> value
      _ -> fallback
    end
  end

  defp integer_or_existing(existing, attrs, key) do
    if map_has_key?(attrs, key), do: integer_attr(attrs, key), else: existing
  end

  defp string_or_existing(existing, attrs, key) do
    if map_has_key?(attrs, key), do: string_attr(attrs, key), else: existing
  end

  defp boolean_or_existing(existing, attrs, key) do
    if map_has_key?(attrs, key), do: boolean_attr(attrs, key, existing), else: existing
  end

  defp map_or_existing(existing, attrs, key) do
    if map_has_key?(attrs, key), do: map_attr(attrs, key, existing), else: existing
  end

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_optional_string()
  defp normalize_optional_string(_), do: nil

  defp normalize_optional_string_list(values) do
    values
    |> List.wrap()
    |> Enum.map(&normalize_optional_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp build_default_integration_name(attrs) do
    string_attr(attrs, "source_type")
    |> case do
      nil -> "Custom Integration"
      source -> source |> String.replace("_", " ") |> String.capitalize()
    end
  end

  defp list_runbooks_for_integration(%AgentIntegration{} = integration) do
    Repo.all(
      from r in AgentRunbook,
        where: r.integration_id == ^integration.id,
        order_by: [asc: r.inserted_at]
    )
    |> Enum.map(fn runbook ->
      %{
        id: runbook.id,
        name: runbook.name,
        eventTypesEnabled: runbook.event_types_enabled || [],
        riskLevel: runbook.risk_level,
        actionType: runbook.action_type,
        instructions: runbook.instructions,
        conditions: runbook.conditions || %{},
        actionConfig: runbook.action_config || %{},
        enabled: runbook.enabled
      }
    end)
  end

  defp sync_runbooks_for_integration!(%Agent{} = agent, %AgentIntegration{} = integration, attrs) do
    raw_runbooks = Map.get(attrs, "runbooks", Map.get(attrs, :runbooks))

    if is_list(raw_runbooks) do
      existing =
        Repo.all(from r in AgentRunbook, where: r.integration_id == ^integration.id)
        |> Map.new(fn runbook -> {runbook.id, runbook} end)

      kept_ids =
        Enum.map(raw_runbooks, fn raw ->
          existing_runbook =
            case Map.get(raw, "id") || Map.get(raw, :id) do
              nil -> %AgentRunbook{}
              runbook_id -> Map.get(existing, runbook_id, %AgentRunbook{})
            end

          runbook =
            existing_runbook
            |> AgentRunbook.changeset(%{
              agent_id: agent.id,
              integration_id: integration.id,
              name: string_attr(raw, "name") || "Runbook",
              event_types_enabled:
                normalize_optional_string_list(
                  Map.get(raw, "event_types_enabled", Map.get(raw, :event_types_enabled, []))
                ),
              risk_level:
                normalize_optional_string(Map.get(raw, "risk_level", Map.get(raw, :risk_level))) || "low",
              action_type:
                string_attr(raw, "action_type")
                || string_attr(raw, "actionType")
                || "post_message",
              instructions:
                string_attr(raw, "instructions")
                || string_attr(raw, "message")
                || string_attr(raw, "text"),
              conditions: map_attr(raw, "conditions", %{}),
              action_config:
                map_attr(raw, "action_config", %{})
                |> maybe_put("message", string_attr(raw, "message"))
                |> maybe_put("title", string_attr(raw, "title")),
              enabled: boolean_attr(raw, "enabled", true)
            })
            |> Repo.insert_or_update!()

          runbook.id
        end)

      existing
      |> Map.keys()
      |> Enum.reject(&(&1 in kept_ids))
      |> Enum.each(fn stale_id ->
        from(r in AgentRunbook, where: r.id == ^stale_id) |> Repo.delete_all()
      end)
    end
  end

  defp refresh_agent_runbook_ids!(agent_id) do
    runbook_ids =
      Repo.all(
        from r in AgentRunbook,
          where: r.agent_id == ^agent_id,
          select: r.id
      )

    from(a in Agent, where: a.id == ^agent_id)
    |> Repo.update_all(set: [runbook_ids: runbook_ids])
  end

  defp map_has_key?(map, key) when is_map(map) do
    key
    |> key_variants()
    |> Enum.any?(fn variant ->
      Map.has_key?(map, variant) ||
        case variant do
          value when is_binary(value) ->
            case safe_existing_atom(value) do
              nil -> false
              atom_key -> Map.has_key?(map, atom_key)
            end

          _ ->
            false
        end
    end)
  end

  defp key_variants(key) when is_binary(key) do
    camel = camelize_lower(key)

    [key, camel]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp key_variants(key), do: [key]

  defp camelize_lower(value) when is_binary(value) do
    camelized = Macro.camelize(value)

    case camelized do
      "" -> nil
      <<first::utf8, rest::binary>> -> String.downcase(<<first::utf8>>) <> rest
    end
  end

  defp safe_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp normalize_attachments_payload(%{"items" => items}) when is_list(items), do: items
  defp normalize_attachments_payload(%{items: items}) when is_list(items), do: items
  defp normalize_attachments_payload(_), do: []

  defp normalize_callback_url(nil), do: nil

  defp normalize_callback_url(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_callback_url(_), do: nil

  defp display_name_from_attrs(attrs, fallback \\ "New Agent") do
    string_attr(attrs, "display_name") ||
      string_attr(attrs, "name") ||
      fallback
  end

  defp normalize_status_update(agent, attrs) do
    requested = Map.get(attrs, "status", Map.get(attrs, :status, agent.status))

    case to_string(requested || agent.status) do
      "draft" -> "draft"
      "published" -> "published"
      "disabled" -> "disabled"
      "archived" -> "archived"
      _ -> agent.status
    end
  end

  defp event_id_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:event_id, _details} -> true
      _ -> false
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
