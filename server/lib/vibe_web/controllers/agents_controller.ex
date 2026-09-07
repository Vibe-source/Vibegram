defmodule VibeWeb.AgentsController do
  use VibeWeb, :controller
  require Logger

  alias Vibe.AgentCard
  alias Vibe.Agents
  alias Vibe.AgentRoutines
  alias Vibe.AgentUsage
  alias Vibe.ProviderContent
  alias Vibe.AI.AgentEventRuntime
  alias Vibe.AI.StandaloneAgent

  @doc """
  Public A2A-compatible agent card for a published agent.
  """
  def card(conn, %{"identifier" => identifier}) do
    case Agents.get_invoke_target(identifier) do
      %{status: "published"} = agent ->
        base_url = VibeWeb.Endpoint.url()
        json(conn, AgentCard.build(agent, base_url))

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  @doc "POST /api/agents/:id/voice/sessions — a call with an isolated agent (docs/agent-voice-v1.md)."
  def voice_session(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    chat_id = params["chatId"] || params["chat_id"]

    with %{} = agent <- Agents.get_agent(id),
         true <- agent.status == "published" or agent.owner_user_id == user.id,
         true <- is_binary(chat_id) and Vibe.Chat.is_participant?(chat_id, user.id),
         true <- Vibe.AgentGateway.enabled?(),
         {:ok, session} <-
           Vibe.AgentGateway.voice_session(%{
             "agentId" => agent.id,
             "userId" => user.id,
             "chatId" => chat_id,
             "agentProfile" => Vibe.AgentGateway.agent_profile(Vibe.Repo.preload(agent, :agent_user))
           }) do
      json(conn, session)
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      false -> conn |> put_status(:forbidden) |> json(%{error: "voice_not_available"})
      {:error, reason} -> conn |> put_status(:bad_gateway) |> json(%{error: "runtime_unavailable", detail: inspect(reason)})
    end
  end

  @doc "GET /api/agents/:id/computer/preview — latest sandbox screenshot (owner only)."
  def computer_preview(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with %{} = agent <- Agents.get_agent(id, user.id),
         true <- Vibe.AgentGateway.enabled?(),
         {:ok, preview} <- Vibe.AgentGateway.computer_preview(agent.id) do
      json(conn, preview)
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      false -> conn |> put_status(:forbidden) |> json(%{error: "computer_not_available"})
      {:error, _reason} -> conn |> put_status(:not_found) |> json(%{error: "no_preview"})
    end
  end

  @doc "GET /api/agents/:id/computer/exec-log — owner-only terminal transcript."
  def computer_exec_log(conn, %{"id" => id} = params) do
    computer_read(conn, id, fn agent ->
      Vibe.AgentGateway.computer_exec_log(agent.id, since: params["since"] || 0, limit: params["limit"] || 40)
    end)
  end

  @doc "GET /api/agents/:id/computer/tree — owner-only directory listing."
  def computer_tree(conn, %{"id" => id} = params) do
    computer_read(conn, id, fn agent ->
      Vibe.AgentGateway.computer_tree(agent.id, path: params["path"] || "", depth: params["depth"] || 2)
    end)
  end

  @doc "GET /api/agents/:id/computer/file?path= — owner-only single file."
  def computer_file(conn, %{"id" => id, "path" => path}) do
    computer_read(conn, id, fn agent -> Vibe.AgentGateway.computer_file(agent.id, path) end)
  end

  def computer_file(conn, _params), do: conn |> put_status(:bad_request) |> json(%{error: "path_required"})

  defp computer_read(conn, id, fun) do
    user = conn.assigns.current_user

    with %{} = agent <- Agents.get_agent(id, user.id),
         true <- Vibe.AgentGateway.enabled?(),
         {:ok, body} when is_map(body) <- fun.(agent) do
      json(conn, body)
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      false -> conn |> put_status(:forbidden) |> json(%{error: "computer_not_available"})
      _ -> conn |> put_status(:bad_gateway) |> json(%{error: "runtime_unavailable"})
    end
  end

  @doc "POST /api/agents/:id/computer/session — owner-only viewer session (docs/agent-computer-v1.md §3.2)."
  def computer_session(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    body = %{
      "viewerId" => user.id,
      "fps" => params["fps"],
      "width" => params["width"],
      "quality" => params["quality"]
    }

    with %{} = agent <- Agents.get_agent(id, user.id),
         true <- Vibe.AgentGateway.enabled?(),
         {:ok, session} when is_map(session) <- Vibe.AgentGateway.computer_session(agent.id, body) do
      json(conn, Map.put(session, "topic", "computer:#{agent.id}"))
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      false -> conn |> put_status(:forbidden) |> json(%{error: "computer_not_available"})
      _ -> conn |> put_status(:bad_gateway) |> json(%{error: "runtime_unavailable"})
    end
  end

  @doc "DELETE /api/agents/:id/computer/session/:session_id — owner-only close."
  def close_computer_session(conn, %{"id" => id, "session_id" => session_id}) do
    user = conn.assigns.current_user

    with %{} = agent <- Agents.get_agent(id, user.id),
         true <- Vibe.AgentGateway.enabled?(),
         {:ok, result} when is_map(result) <- Vibe.AgentGateway.close_computer_session(agent.id, session_id) do
      json(conn, result)
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      false -> conn |> put_status(:forbidden) |> json(%{error: "computer_not_available"})
      _ -> conn |> put_status(:bad_gateway) |> json(%{error: "runtime_unavailable"})
    end
  end

  def index(conn, _params) do
    viewer = conn.assigns.current_user
    quota = Agents.quota_for_user(viewer.id)

    items =
      viewer.id
      |> Agents.list_agents()
      |> Enum.map(&Agents.agent_payload/1)

    json(conn, %{items: team_items(viewer) ++ items, quota: quota})
  end

  # The built-in team has no `agents` row on purpose, so an admin gets it synthesised.
  defp team_items(viewer) do
    if Vibe.Admins.can?(viewer, "agents.read") do
      Vibe.AI.LocalAgentWorker.workers()
      |> Map.values()
      |> Enum.sort_by(&Map.get(&1, :handle))
      |> Enum.map(&team_item/1)
    else
      []
    end
  end

  defp team_item(worker) do
    %{
      id: worker[:agent_user_id],
      userId: worker[:agent_user_id],
      username: worker[:username],
      publicLink: nil,
      displayName: worker[:name] || worker[:label],
      status: "published",
      builtin: true,
      modelProvider: worker[:executor] || worker[:handle],
      modelId: worker[:model],
      systemPrompt: nil,
      promptVariables: [],
      persona: worker[:label],
      avatarUrl: worker[:avatar_url],
      welcomeMessage: nil,
      enabledTools: [],
      outputModes: [],
      autonomyMode: "approval_required",
      executionMode: to_string(worker[:runtime] || :bridge),
      defaultDestinationChatId: nil,
      eventTypesEnabled: [],
      costBudgetDaily: nil,
      costBudgetMonthly: nil,
      approvalRules: %{},
      runbookIds: [],
      voiceProvider: nil,
      voiceProfile: nil,
      callbackUrl: nil,
      secretHint: nil,
      previousSecretExpiresAt: nil,
      publishedAt: nil,
      lastInvokedAt: nil,
      attachedChats: [],
      integrations: []
    }
  end

  @doc """
  Returns the catalog of tools an agent can be granted.
  """
  def tool_registry(conn, _params) do
    json(conn, %{items: Vibe.AI.ToolRegistry.toggleable_tools()})
  end

  @doc "Returns the server-authoritative provider and model catalog."
  def model_registry(conn, _params) do
    json(conn, Vibe.AI.ModelRegistry.public_payload())
  end

  @doc """
  Live availability check for an agent handle/username.
  """
  def username_available(conn, params) do
    owner_id = conn.assigns.current_user.id
    username = params["username"] || ""

    agent =
      case params["agent_id"] || params["id"] do
        id when is_binary(id) and id != "" -> Agents.get_agent(id, owner_id)
        _ -> nil
      end

    case Agents.username_availability(username, agent) do
      {:ok, normalized} -> json(conn, %{available: true, username: normalized})
      {:error, reason} -> json(conn, %{available: false, reason: to_string(reason)})
    end
  end

  def create(conn, params) do
    owner_id = conn.assigns.current_user.id

    case Agents.create_agent(owner_id, params) do
      {:ok, agent, secret} ->
        json(conn, %{
          agent: Agents.agent_payload(agent, quota: Agents.quota_for_user(owner_id)),
          secret: secret
        })

      {:error, :quota_exceeded} ->
        conn |> put_status(:forbidden) |> json(%{error: "Agent limit reached"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def show(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    case Agents.get_agent(id, owner_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agent not found"})
      agent -> json(conn, Agents.agent_payload(agent, quota: Agents.quota_for_user(owner_id)))
    end
  end

  def secret(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, secret} <- Agents.callback_signing_secret(agent) do
      json(conn, %{secret: secret, secretHint: agent.secret_hint})
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, updated} <- Agents.update_agent(agent, Map.delete(params, "id"), owner_id) do
      json(conn, Agents.agent_payload(updated, quota: Agents.quota_for_user(owner_id)))
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def publish(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, updated} <- Agents.publish_agent(agent, owner_id) do
      json(conn, Agents.agent_payload(updated, quota: Agents.quota_for_user(owner_id)))
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: publish_error_message(reason), code: publish_error_code(reason)})
    end
  end

  defp publish_error_message(:missing_system_prompt),
    do: "Add a system prompt before publishing this agent."

  defp publish_error_message(:missing_output_modes),
    do: "Pick at least one output mode before publishing this agent."

  defp publish_error_message(:voice_unavailable),
    do: "Voice output is not configured on this server. Remove voice from the output modes to publish."

  defp publish_error_message(:forbidden), do: "You do not own this agent."
  defp publish_error_message(_reason), do: "Could not publish agent."

  defp publish_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp publish_error_code(_reason), do: "publish_failed"

  def rotate_secret(conn, %{"id" => id} = params) do
    owner_id = conn.assigns.current_user.id

    grace_hours = params["graceHours"] || params["grace_hours"]

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, updated, secret} <-
           Agents.rotate_secret(agent, owner_id, grace_hours: grace_hours) do
      json(conn, %{
        agent: Agents.agent_payload(updated),
        secret: secret,
        previousSecretExpiresAt: updated.previous_secret_expires_at
      })
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      {:error, :invalid_grace_hours} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "graceHours must be a whole number of hours"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def deliveries(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    case Agents.get_agent(id, owner_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agent not found"})
      agent -> json(conn, Agents.list_delivery_data(agent))
    end
  end

  def owner_usage(conn, _params) do
    json(conn, AgentUsage.owner_summary(conn.assigns.current_user.id))
  end

  def agent_usage(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    case Agents.get_agent(id, owner_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      agent -> json(conn, AgentUsage.agent_summary(agent.id))
    end
  end

  def routines(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    case Agents.get_agent(id, owner_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      agent ->
        items = agent.id |> AgentRoutines.list_for_agent(owner_id) |> Enum.map(&AgentRoutines.routine_payload/1)
        json(conn, %{items: items})
    end
  end

  def create_routine(conn, %{"id" => id} = params) do
    owner_id = conn.assigns.current_user.id

    case Agents.get_agent(id, owner_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      agent ->
        case AgentRoutines.create(owner_id, agent, Map.delete(params, "id")) do
          {:ok, routine} -> json(conn, AgentRoutines.routine_payload(routine))
          {:error, reason} -> routine_error(conn, reason)
        end
    end
  end

  def update_routine(conn, %{"id" => id, "routine_id" => routine_id} = params) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         %{} = routine <- AgentRoutines.get(routine_id, owner_id),
         true <- routine.agent_id == agent.id do
      case AgentRoutines.update(routine, Map.drop(params, ["id", "routine_id"])) do
        {:ok, updated} -> json(conn, AgentRoutines.routine_payload(updated))
        {:error, reason} -> routine_error(conn, reason)
      end
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def delete_routine(conn, %{"id" => id, "routine_id" => routine_id}) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         %{} = routine <- AgentRoutines.get(routine_id, owner_id),
         true <- routine.agent_id == agent.id,
         {:ok, _} <- AgentRoutines.delete(routine) do
      json(conn, %{success: true})
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  defp routine_error(conn, :agent_not_published),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "agent_not_published"})

  defp routine_error(conn, :not_in_chat),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "not_in_chat"})

  defp routine_error(conn, :routine_limit),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "routine_limit"})

  defp routine_error(conn, :not_found),
    do: conn |> put_status(:not_found) |> json(%{error: "not_found"})

  defp routine_error(conn, %Ecto.Changeset{} = changeset),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: first_changeset_error(changeset)})

  defp routine_error(conn, reason),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})

  defp first_changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc -> String.replace(acc, "%{#{key}}", to_string(value)) end)
    end)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field} #{&1}") end)
    |> List.first()
  end

  def delete(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, _} <- Agents.archive_agent(agent, owner_id) do
      json(conn, %{success: true})
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def invoke(conn, %{"identifier" => identifier} = params) do
    secret = List.first(get_req_header(conn, "x-vibe-agent-secret"))

    Logger.info(
      "[AgentsController] invoke start " <>
        "identifier=#{identifier} method=#{conn.method} path=#{conn.request_path} " <>
        "content_type=#{List.first(get_req_header(conn, "content-type")) || "unknown"} " <>
        "secret_present=#{is_binary(secret)} params_keys=#{inspect(Map.keys(params) |> Enum.sort())}"
    )

    with %{} = agent <- Agents.get_invoke_target(identifier),
         :ok <- ensure_agent_published(agent),
         :ok <- ensure_secret(agent, secret),
         {:ok, params} <- merge_provider_content(params),
         {:ok, result} <- StandaloneAgent.invoke(agent, params),
         {:ok, invocation} <-
           Agents.record_invocation(agent, %{
             source: params["source"] || "external",
             event_id: params["eventId"] || params["event_id"],
             vibe_chat_id: params["vibeChatId"] || params["vibe_chat_id"],
             external_user_id: params["externalUserId"] || params["external_user_id"],
             request_payload: Map.drop(params, ["identifier"]),
             response_payload: result,
             status: "completed"
           }) do
      Logger.info(
        "[AgentsController] invoke success " <>
          "identifier=#{identifier} agent_id=#{agent.id} invocation_id=#{invocation.id} " <>
          "outputs=#{length(Map.get(result, :outputs, Map.get(result, "outputs", [])) || [])}"
      )

      if is_binary(agent.callback_url) and String.trim(agent.callback_url) != "" do
        _ = Agents.create_delivery_event(agent, invocation, "agent.invocation.completed", result)
      end

      json(conn, result |> Map.put(:success, true) |> Map.put(:invocationId, invocation.id))
    else
      nil ->
        Logger.warning("[AgentsController] invoke missing agent identifier=#{identifier}")
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      {:error, :agent_unavailable} ->
        Logger.warning("[AgentsController] invoke unavailable identifier=#{identifier}")
        conn |> put_status(:forbidden) |> json(%{error: "Agent unavailable"})

      {:error, :invalid_secret} ->
        Logger.warning("[AgentsController] invoke invalid secret identifier=#{identifier}")
        conn |> put_status(:unauthorized) |> json(%{error: "Invalid secret"})

      {:error, :chat_not_attached} ->
        Logger.warning("[AgentsController] invoke chat not attached identifier=#{identifier}")
        conn |> put_status(:forbidden) |> json(%{error: "Agent not attached to target chat"})

      {:error, {:invalid_content, reason}} ->
        Logger.warning(
          "[AgentsController] invoke invalid content identifier=#{identifier} reason=#{inspect(reason)}"
        )

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_content"})

      {:error, reason} ->
        Logger.error(
          "[AgentsController] invoke failed identifier=#{identifier} reason=#{inspect(reason)}"
        )

        conn |> put_status(:unprocessable_entity) |> json(%{error: "request_failed"})
    end
  end

  defp merge_provider_content(%{"content" => %{"contract" => _} = content} = params) do
    case ProviderContent.parse(content) do
      {:ok, normalized} ->
        attrs = ProviderContent.to_message_attrs(normalized)
        merged_attachments = List.wrap(params["attachments"]) ++ (attrs["attachments"] || [])

        {:ok,
         params
         |> Map.put("message", attrs["text"])
         |> Map.put("attachments", merged_attachments)
         |> Map.put("providerContent", normalized)}

      {:error, reason} ->
        {:error, {:invalid_content, reason}}
    end
  end

  defp merge_provider_content(params), do: {:ok, params}

  def integrations(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    case Agents.get_agent(id, owner_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      agent ->
        items =
          agent
          |> Agents.list_integrations()
          |> Enum.map(&Agents.integration_payload/1)

        json(conn, %{items: items})
    end
  end

  def create_integration(conn, %{"id" => id} = params) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, integration, secret} <-
           Agents.create_integration(agent, Map.drop(params, ["id"]), owner_id) do
      json(conn, %{
        integration: Agents.integration_payload(integration, latest_secret: secret),
        secret: secret
      })
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def update_integration(conn, %{"id" => id, "integration_id" => integration_id} = params) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         %{} = integration <- Agents.get_integration(agent, integration_id),
         {:ok, updated} <-
           Agents.update_integration(
             integration,
             Map.drop(params, ["id", "integration_id"]),
             owner_id
           ) do
      json(conn, %{integration: Agents.integration_payload(updated)})
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Integration not found"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def events(conn, %{"id" => id} = params) do
    owner_id = conn.assigns.current_user.id
    limit = bounded_integer(params["limit"], 200, 1, 500)
    offset = bounded_integer(params["offset"], 0, 0, 100_000)

    case Agents.get_agent(id, owner_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      agent ->
        {events, total} = Agents.list_events(agent, limit: limit, offset: offset)

        json(conn, %{
          items: Enum.map(events, &Agents.event_payload/1),
          total: total,
          limit: limit,
          offset: offset,
          hasMore: offset + length(events) < total
        })
    end
  end

  def threads(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    case Agents.get_agent(id, owner_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      agent ->
        items =
          agent
          |> Agents.list_threads()
          |> Enum.map(&Agents.thread_payload/1)

        json(conn, %{items: items})
    end
  end

  def thread(conn, %{"id" => id, "thread_id" => thread_id}) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         %{} = thread <- Agents.get_thread(agent, thread_id) do
      json(conn, %{thread: Agents.thread_payload(thread, details: true)})
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Thread not found"})
    end
  end

  def approve_task(conn, %{"id" => id, "task_id" => task_id} = params) do
    owner_id = conn.assigns.current_user.id
    note = params["note"]

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, task} <- Agents.approve_task(agent, task_id, owner_id, note),
         {:ok, execution} <- AgentEventRuntime.execute_approved_task(agent, task) do
      json(conn, %{task: Agents.approval_task_payload(task), execution: execution})
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Task not found"})

      {:error, :already_decided} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Task already decided"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def reject_task(conn, %{"id" => id, "task_id" => task_id} = params) do
    owner_id = conn.assigns.current_user.id
    note = params["note"]

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, task} <- Agents.reject_task(agent, task_id, owner_id, note) do
      json(conn, %{task: Agents.approval_task_payload(task)})
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Task not found"})

      {:error, :already_decided} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Task already decided"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  @doc """
  Claim a sender-declared decision action by opaque token.
  """
  def respond_decision_action(conn, params) when is_map(params) do
    user_id = conn.assigns.current_user.id
    token = params["token"] || params["actionToken"] || params["action_token"]

    case Vibe.AI.AgentDecisions.respond(user_id, token) do
      {:ok, %{task: task, action: action, actor: actor}} ->
        json(conn, %{
          ok: true,
          task: Agents.approval_task_payload(task),
          action: %{
            id: action.action_id,
            label: action.label,
            style: action.style,
            status: action.status
          },
          decidedByUserId: actor && actor.id
        })

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, :invalid_token} ->
        conn |> put_status(:not_found) |> json(%{error: "invalid_token"})

      {:error, :already_decided} ->
        conn |> put_status(:conflict) |> json(%{error: "already_decided", ok: false})

      {:error, :expired} ->
        conn |> put_status(:gone) |> json(%{error: "expired"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  def ingest_event(conn, params) when is_map(params) do
    identifier = params["identifier"] || conn.path_params["identifier"]

    secret =
      List.first(get_req_header(conn, "x-vibe-agent-secret")) ||
        List.first(get_req_header(conn, "x-vibe-integration-secret"))

    Logger.info(
      "[AgentsController] ingest_event start " <>
        "identifier=#{identifier || "missing"} method=#{conn.method} path=#{conn.request_path} " <>
        "content_type=#{List.first(get_req_header(conn, "content-type")) || "unknown"} " <>
        "secret_present=#{is_binary(secret)} raw_body_bytes=#{byte_size(conn.assigns[:raw_body] || "")} " <>
        "params_keys=#{inspect(Map.keys(params) |> Enum.sort())}"
    )

    try do
      with true <- is_binary(identifier),
           %{} = agent <- Agents.get_invoke_target(identifier),
           :ok <- ensure_agent_published(agent),
           {:ok, event_params} <- merge_provider_content(Map.drop(params, ["identifier"])),
           {:ok, result} <- AgentEventRuntime.ingest(agent, event_params, secret: secret) do
        Logger.info(
          "[AgentsController] ingest_event success " <>
            "identifier=#{identifier} agent_id=#{agent.id} result=#{inspect(result)}"
        )

        json(conn, result)
      else
        false ->
          Logger.warning("[AgentsController] ingest_event missing identifier")
          conn |> put_status(:bad_request) |> json(%{error: "Missing agent identifier"})

        nil ->
          Logger.warning("[AgentsController] ingest_event missing agent identifier=#{identifier}")
          conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

        {:error, :agent_unavailable} ->
          Logger.warning("[AgentsController] ingest_event unavailable identifier=#{identifier}")
          conn |> put_status(:forbidden) |> json(%{error: "Agent unavailable"})

        {:error, :invalid_secret} ->
          Logger.warning(
            "[AgentsController] ingest_event invalid secret identifier=#{identifier}"
          )

          conn |> put_status(:unauthorized) |> json(%{error: "Invalid secret"})

        {:error, :chat_not_attached} ->
          Logger.warning(
            "[AgentsController] ingest_event chat not attached identifier=#{identifier}"
          )

          conn |> put_status(:forbidden) |> json(%{error: "Agent not attached to target chat"})

        {:error, :event_trigger_not_enabled} ->
          Logger.warning(
            "[AgentsController] ingest_event trigger not enabled identifier=#{identifier}"
          )

          conn
          |> put_status(:forbidden)
          |> json(%{error: "event_trigger_not_enabled"})

        {:error, :missing_destination_chat} ->
          Logger.warning(
            "[AgentsController] ingest_event missing destination chat identifier=#{identifier}"
          )

          conn |> put_status(:unprocessable_entity) |> json(%{error: "Missing destination chat"})

        {:error, :missing_event_type} ->
          Logger.warning(
            "[AgentsController] ingest_event missing event type identifier=#{identifier}"
          )

          conn |> put_status(:unprocessable_entity) |> json(%{error: "eventType is required"})

        {:error, :event_payload_too_large} ->
          Logger.warning(
            "[AgentsController] ingest_event payload too large identifier=#{identifier}"
          )

          conn |> put_status(:payload_too_large) |> json(%{error: "event_payload_too_large"})

        {:error, :stream_payload_too_large} ->
          Logger.warning(
            "[AgentsController] ingest_event stream payload too large identifier=#{identifier}"
          )

          conn |> put_status(:payload_too_large) |> json(%{error: "stream_payload_too_large"})

        {:error, {:invalid_content, reason}} ->
          Logger.warning(
            "[AgentsController] ingest_event invalid content identifier=#{identifier} reason=#{inspect(reason)}"
          )

          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "invalid_content"})

        {:error, reason} ->
          Logger.error(
            "[AgentsController] ingest_event failed identifier=#{identifier} reason=#{inspect(reason)}"
          )

          conn |> put_status(:unprocessable_entity) |> json(%{error: "event_ingest_failed"})
      end
    rescue
      exception ->
        Logger.error(
          "[AgentsController] ingest_event exception " <>
            "identifier=#{identifier || "missing"} exception=#{inspect(exception)} " <>
            "stacktrace=#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        reraise exception, __STACKTRACE__
    end
  end

  defp bounded_integer(value, fallback, minimum, maximum) do
    parsed =
      cond do
        is_integer(value) ->
          value

        is_binary(value) ->
          case Integer.parse(value) do
            {number, _} -> number
            :error -> fallback
          end

        true ->
          fallback
      end

    parsed
    |> max(minimum)
    |> min(maximum)
  end

  defp ensure_agent_published(%{status: "published"}), do: :ok
  defp ensure_agent_published(_agent), do: {:error, :agent_unavailable}

  defp ensure_secret(agent, secret) do
    if Agents.verify_secret(agent, secret), do: :ok, else: {:error, :invalid_secret}
  end
end
