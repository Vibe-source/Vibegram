defmodule Vibe.AI.AgentDecisions do
  @moduledoc """
  Sender-declared decision sets on agent events.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.AgentApprovalTask
  alias Vibe.AgentDecisionAction
  alias Vibe.AgentEvent
  alias Vibe.AgentEventThread
  alias Vibe.AgentGateway
  alias Vibe.Agents
  alias Vibe.Chat
  alias Vibe.Chat.AgentMessageCrypto
  alias Vibe.Chat.Message
  alias Vibe.Repo
  alias Vibe.RepoRLS

  @max_actions 8
  @max_label_length 48
  @max_confirm_length 200
  @action_id_re ~r/^[a-z0-9_-]{1,32}$/
  @styles ~w[primary secondary destructive default]
  @action_modes ~w[single multi]
  @default_ttl_seconds 7 * 24 * 3600
  @service_key "service"
  @service_version 1

  # ── Validation / normalization (public for unit tests) ─────────────────────

  @doc """
  Parse and validate a sender-declared action set from event params.
  """
  def normalize_declaration(params) when is_map(params) do
    raw_actions = params["actions"] || params[:actions]

    cond do
      is_nil(raw_actions) ->
        {:ok, nil}

      is_list(raw_actions) and raw_actions == [] ->
        {:ok, nil}

      not is_list(raw_actions) ->
        {:error, :invalid_actions}

      length(raw_actions) > @max_actions ->
        {:error, :too_many_actions}

      true ->
        with {:ok, actions} <- normalize_actions(raw_actions),
             {:ok, mode} <- normalize_action_mode(params["actionMode"] || params["action_mode"]),
             {:ok, expires_at} <-
               normalize_expires_at(params["expiresAt"] || params["expires_at"]) do
          {:ok,
           %{
             actions: actions,
             action_mode: mode,
             expires_at: expires_at
           }}
        end
    end
  end

  def normalize_declaration(_), do: {:ok, nil}

  @doc false
  def service_key, do: @service_key

  @doc """
  Build a structured service-message node for message.metadata.
  """
  def service_node(attrs) when is_map(attrs) do
    kind = Map.get(attrs, :kind) || Map.get(attrs, "kind") || "custom"
    text = Map.get(attrs, :text) || Map.get(attrs, "text") || ""

    parts =
      Map.get(attrs, :parts) || Map.get(attrs, "parts") || [%{"type" => "plain", "value" => text}]

    status = Map.get(attrs, :status) || Map.get(attrs, "status") || "active"
    decision = Map.get(attrs, :decision) || Map.get(attrs, "decision")

    node = %{
      "kind" => to_string(kind),
      "version" => @service_version,
      "text" => text,
      "parts" => parts,
      "status" => to_string(status)
    }

    if is_map(decision), do: Map.put(node, "decision", decision), else: node
  end

  def membership_service_node(action, actor_name, target_name) do
    {kind, template_key, text} =
      case action do
        "member_added" ->
          {"member_added", "membership.added", "#{actor_name} added #{target_name}"}

        "member_joined" ->
          {"member_joined", "membership.joined", "#{target_name} joined the group"}

        "member_removed" ->
          {"member_removed", "membership.removed", "#{actor_name} removed #{target_name}"}

        "member_left" ->
          {"member_left", "membership.left", "#{target_name} left the group"}

        _ ->
          {"custom", "membership.custom", ""}
      end

    service_node(%{
      kind: kind,
      text: text,
      status: "active",
      parts: [
        %{
          "type" => "template",
          "key" => template_key,
          "args" => %{
            "actorName" => actor_name,
            "targetName" => target_name
          }
        }
      ]
    })
  end


  def create_declared_decision(agent, thread, event, normalized, declaration, policy) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = declaration.expires_at || DateTime.add(now, @default_ttl_seconds, :second)

    title = normalized.title || normalized.event_type || "Decision required"
    detail = normalized.text

    prepared =
      declaration.actions
      |> Enum.with_index()
      |> Enum.map(fn {action, index} ->
        {token, hash} = generate_action_token()
        {action, index, token, hash}
      end)

    task =
      %AgentApprovalTask{}
      |> AgentApprovalTask.changeset(%{
        agent_id: agent.id,
        thread_id: thread.id,
        event_id: event.id,
        runbook_id: nil,
        chat_id: thread.chat_id,
        requested_action: %{
          "actionType" => "sender_declared",
          "title" => title,
          "message" => detail,
          "eventType" => normalized.event_type,
          "threadKey" => thread.thread_key
        },
        rationale: "Sender declared decision actions for #{normalized.event_type}",
        status: "pending",
        action_mode: declaration.action_mode,
        expires_at: expires_at,
        source: "declared"
      })
      |> Repo.insert!()

    Enum.each(prepared, fn {action, index, _token, hash} ->
      %AgentDecisionAction{}
      |> AgentDecisionAction.changeset(%{
        task_id: task.id,
        action_id: action.id,
        label: action.label,
        style: action.style,
        confirm: action.confirm,
        token_hash: hash,
        status: "pending",
        position: index
      })
      |> Repo.insert!()
    end)

    client_actions =
      Enum.map(prepared, fn {action, _index, token, _hash} ->
        %{
          "id" => action.id,
          "label" => action.label,
          "style" => action.style,
          "confirm" => action.confirm,
          "token" => token
        }
      end)

    service =
      service_node(%{
        kind: "decision",
        text: title,
        status: "pending",
        parts: decision_pending_parts(title, detail),
        decision: %{
          "taskId" => task.id,
          "actionMode" => declaration.action_mode,
          "expiresAt" => DateTime.to_iso8601(expires_at),
          "actions" => client_actions,
          "chosen" => nil
        }
      })

    body = if is_binary(detail) and detail != "", do: "#{title}\n\n#{detail}", else: title

    metadata = %{
      @service_key => service,
      "eventThreadId" => thread.id,
      "eventId" => event.id,
      "approvalTaskId" => task.id,
      "status" => "pending_decision",
      "priority" => policy.priority
    }

    with {:ok, message_payload} <-
           post_decision_message(agent, thread.chat_id, thread.root_message_id, body, metadata) do
      task =
        task
        |> AgentApprovalTask.changeset(%{message_id: message_payload.message_id})
        |> Repo.update!()

      {:ok, %{status: "approval_required", approval_task: task, message: message_payload}}
    end
  end

  @doc """
  Runtime-sourced decision (isolated run approval/permission). Same message/token
  plumbing as `create_declared_decision/6`, but no thread/event to attach to.
  """
  def create_runtime_decision(agent, chat_id, params) when is_map(params) do
    run_id = params["runId"] || params[:runId]
    decision_id = params["decisionId"] || params[:decisionId]
    kind = params["kind"] || params[:kind] || "approval"
    capability = params["capability"] || params[:capability]
    scope = params["scope"] || params[:scope]
    title = params["title"] || params[:title] || default_decision_title(kind, capability)
    detail = params["detail"] || params[:detail] || params["reason"] || params[:reason]
    risk = params["risk"] || params[:risk]

    raw_actions =
      case params["actions"] || params[:actions] || [] do
        [] -> default_decision_actions(kind)
        actions -> actions
      end

    with {:ok, action_mode} <- normalize_action_mode(params["actionMode"] || params[:actionMode]),
         {:ok, expires_at} <- normalize_expires_at(params["expiresAt"] || params[:expiresAt]),
         {:ok, actions} <- normalize_actions(raw_actions) do
      prepared =
        actions
        |> Enum.with_index()
        |> Enum.map(fn {action, index} ->
          {token, hash} = generate_action_token()
          {action, index, token, hash}
        end)

      task =
        %AgentApprovalTask{}
        |> AgentApprovalTask.changeset(%{
          agent_id: agent.id,
          chat_id: chat_id,
          requested_action: %{
            "actionType" => "runtime_decision",
            "runId" => run_id,
            "decisionId" => decision_id,
            "kind" => kind,
            "risk" => risk,
            "capability" => capability,
            "scope" => scope,
            "tool" => params["tool"] || params[:tool]
          },
          rationale: "Runtime decision request for run #{run_id}",
          status: "pending",
          action_mode: action_mode,
          expires_at: expires_at,
          source: "runtime"
        })
        |> Repo.insert!()

      Enum.each(prepared, fn {action, index, _token, hash} ->
        %AgentDecisionAction{}
        |> AgentDecisionAction.changeset(%{
          task_id: task.id,
          action_id: action.id,
          label: action.label,
          style: action.style,
          confirm: action.confirm,
          token_hash: hash,
          status: "pending",
          position: index
        })
        |> Repo.insert!()
      end)

      client_actions =
        Enum.map(prepared, fn {action, _index, token, _hash} ->
          %{
            "id" => action.id,
            "label" => action.label,
            "style" => action.style,
            "confirm" => action.confirm,
            "token" => token
          }
        end)

      service =
        service_node(%{
          kind: "decision",
          text: title,
          status: "pending",
          parts: decision_pending_parts(title, detail),
          decision: %{
            "taskId" => task.id,
            "actionMode" => action_mode,
            "expiresAt" => DateTime.to_iso8601(expires_at),
            "actions" => client_actions,
            "chosen" => nil,
            "risk" => risk,
            "capability" => capability,
            "scope" => scope,
            "tool" => params["tool"] || params[:tool]
          }
        })

      body = if is_binary(detail) and detail != "", do: "#{title}\n\n#{detail}", else: title

      metadata = %{
        @service_key => service,
        "status" => "pending_decision",
        "runId" => run_id,
        "decisionId" => decision_id
      }

      with {:ok, message_payload} <- post_decision_message(agent, chat_id, nil, body, metadata) do
        task =
          task
          |> AgentApprovalTask.changeset(%{message_id: message_payload.message_id})
          |> Repo.update!()

        {:ok, %{taskId: task.id, messageId: message_payload.message_id}}
      end
    end
  end

  @doc "True when `decision_id` is a pending/decided runtime-sourced decision task."
  def runtime_decision?(decision_id) when is_binary(decision_id) and decision_id != "" do
    not is_nil(runtime_decision_run_id(decision_id))
  end

  def runtime_decision?(_decision_id), do: false

  @doc "The `runId` embedded in a runtime-sourced task's requested_action, or nil."
  def runtime_decision_run_id(decision_id) when is_binary(decision_id) and decision_id != "" do
    Repo.one(
      from(t in AgentApprovalTask,
        where:
          t.source == "runtime" and
            fragment("?->>'decisionId' = ?", t.requested_action, ^decision_id),
        select: fragment("?->>'runId'", t.requested_action),
        limit: 1
      )
    )
  end

  def runtime_decision_run_id(_decision_id), do: nil

  @doc "`%{taskId:, messageId:}` of the task already created for `decision_id`, or nil."
  def runtime_decision_refs(decision_id) when is_binary(decision_id) and decision_id != "" do
    Repo.one(
      from(t in AgentApprovalTask,
        where:
          t.source == "runtime" and
            fragment("?->>'decisionId' = ?", t.requested_action, ^decision_id),
        select: %{taskId: t.id, messageId: t.message_id},
        limit: 1
      )
    )
  end

  def runtime_decision_refs(_decision_id), do: nil


  @doc """
  Claim a decision action by its opaque token.
  """
  def respond(user_id, token) when is_binary(user_id) and is_binary(token) do
    token = String.trim(token)

    if token == "" do
      {:error, :invalid_token}
    else
      hash = hash_token(token)

      Repo.transaction(fn ->
        case lookup_pending_action(hash) do
          nil ->
            case lookup_any_action(hash) do
              nil ->
                Repo.rollback(:invalid_token)

              %AgentDecisionAction{status: "chosen"} ->
                Repo.rollback(:already_decided)

              %AgentDecisionAction{status: status} when status in ~w[superseded expired] ->
                Repo.rollback(:already_decided)

              _ ->
                Repo.rollback(:invalid_token)
            end

          {%AgentDecisionAction{} = action, %AgentApprovalTask{} = task} ->
            cond do
              task.status != "pending" ->
                Repo.rollback(:already_decided)

              expired?(task) ->
                _ = expire_task!(task)
                Repo.rollback(:expired)

              not authorized_responder?(task, user_id) ->
                Repo.rollback(:forbidden)

              true ->
                case claim_action!(task, action, user_id) do
                  {:ok, result} ->
                    result

                  {:error, reason} ->
                    Repo.rollback(reason)
                end
            end
        end
      end)
      |> case do
        {:ok, result} ->
          _ = maybe_dispatch_callback(result)
          _ = settle_message(result)
          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def respond(_user_id, _token), do: {:error, :invalid_token}

  @doc """
  Expire pending decision sets past their deadline. Called from the delivery
  scheduler poll loop.
  """
  def expire_due_tasks(limit \\ 50) when is_integer(limit) and limit > 0 do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    task_ids =
      Repo.all(
        from(t in AgentApprovalTask,
          where: t.status == "pending" and not is_nil(t.expires_at) and t.expires_at <= ^now,
          select: t.id,
          limit: ^limit
        )
      )

    Enum.reduce(task_ids, 0, fn task_id, count ->
      case expire_task_by_id(task_id) do
        {:ok, _} -> count + 1
        _ -> count
      end
    end)
  end


  defp normalize_actions(raw_actions) do
    raw_actions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      case normalize_one_action(raw, index) do
        {:ok, action} -> {:cont, {:ok, [action | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, actions} ->
        actions = Enum.reverse(actions)
        ids = Enum.map(actions, & &1.id)

        cond do
          actions == [] -> {:error, :invalid_actions}
          length(ids) != length(Enum.uniq(ids)) -> {:error, :duplicate_action_id}
          true -> {:ok, actions}
        end

      error ->
        error
    end
  end

  defp normalize_one_action(raw, _index) when not is_map(raw), do: {:error, :invalid_action}

  defp normalize_one_action(raw, index) do
    id = raw["id"] || raw[:id]
    label = raw["label"] || raw[:label]
    style = raw["style"] || raw[:style] || "secondary"
    confirm = raw["confirm"] || raw[:confirm]

    _ = raw["callbackUrl"] || raw["callback_url"] || raw["token"] || raw["url"]

    cond do
      not is_binary(id) or not Regex.match?(@action_id_re, id) ->
        {:error, :invalid_action_id}

      not is_binary(label) ->
        {:error, :invalid_action_label}

      true ->
        label = String.trim(label)

        cond do
          label == "" or String.length(label) > @max_label_length ->
            {:error, :invalid_action_label}

          not is_binary(style) or style not in @styles ->
            {:error, :invalid_action_style}

          not valid_confirm?(confirm) ->
            {:error, :invalid_action_confirm}

          true ->
            {:ok,
             %{
               id: id,
               label: label,
               style: style,
               confirm: normalize_confirm(confirm),
               position: index
             }}
        end
    end
  end

  defp valid_confirm?(nil), do: true

  defp valid_confirm?(value) when is_binary(value),
    do: String.length(value) <= @max_confirm_length

  defp valid_confirm?(_), do: false

  defp normalize_confirm(nil), do: nil

  defp normalize_confirm(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_action_mode(nil), do: {:ok, "single"}
  defp normalize_action_mode(mode) when mode in @action_modes, do: {:ok, mode}
  defp normalize_action_mode(_), do: {:error, :invalid_action_mode}

  defp normalize_expires_at(nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, DateTime.add(now, @default_ttl_seconds, :second)}
  end

  defp normalize_expires_at(%DateTime{} = dt) do
    now = DateTime.utc_now()

    if DateTime.compare(dt, now) == :gt do
      {:ok, DateTime.truncate(dt, :second)}
    else
      {:error, :expires_at_not_future}
    end
  end

  defp normalize_expires_at(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, dt, _} -> normalize_expires_at(dt)
      _ -> {:error, :invalid_expires_at}
    end
  end

  defp normalize_expires_at(_), do: {:error, :invalid_expires_at}

  defp generate_action_token do
    token = "vat_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {token, hash_token(token)}
  end

  defp hash_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  defp default_decision_title("permission", capability) when is_binary(capability) and capability != "" do
    "Allow access to #{capability}?"
  end

  defp default_decision_title(_kind, _capability), do: "Decision required"

  defp default_decision_actions("permission") do
    [
      %{"id" => "allow_once", "label" => "Allow once", "style" => "primary"},
      %{"id" => "allow_run", "label" => "Allow for this run", "style" => "primary"},
      %{"id" => "deny", "label" => "Deny", "style" => "destructive"}
    ]
  end

  defp default_decision_actions(_kind), do: []

  defp decision_pending_parts(title, detail) do
    parts = [%{"type" => "plain", "value" => title}]

    if is_binary(detail) and String.trim(detail) != "" do
      parts ++ [%{"type" => "plain", "value" => detail}]
    else
      parts
    end
  end

  defp post_decision_message(agent, chat_id, reply_to_id, body, metadata) do
    message_id = Ecto.UUID.generate()
    timestamp = System.system_time(:millisecond)

    agent_username =
      case agent.agent_user do
        %{username: username} when is_binary(username) -> username
        _ -> nil
      end

    attrs =
      %{
        id: message_id,
        chat_id: chat_id,
        from_id: agent.agent_user_id,
        encrypted_content: AgentMessageCrypto.encrypt_for_storage(body || ""),
        type: "system",
        metadata:
          metadata
          |> Map.put("isAgentMessage", true)
          |> Map.put("agentName", agent.display_name)
          |> Map.put("agentId", agent.id)
          |> Map.put("agentUserId", agent.agent_user_id)
          |> Map.put("agentUsername", agent_username)
          |> Map.put(
            "agentHandle",
            if(agent_username, do: "@#{agent_username}", else: nil)
          )
          |> Map.put("text", body),
        reply_to_id: reply_to_id,
        timestamp: timestamp
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Chat.add_message(attrs, acting_user_id: agent.agent_user_id) do
      {:ok, _message} ->
        payload = %{
          "id" => message_id,
          "fromId" => agent.agent_user_id,
          "chatId" => chat_id,
          "encryptedContent" => "",
          "plainContent" => body,
          "plaintext" => body,
          "type" => "system",
          "timestamp" => timestamp,
          "status" => "sent",
          "metadata" => attrs.metadata,
          "isAgentMessage" => true
        }

        VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message", payload)

        {:ok, %{message_id: message_id, payload: payload}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lookup_pending_action(hash) do
    Repo.one(
      from(a in AgentDecisionAction,
        join: t in AgentApprovalTask,
        on: t.id == a.task_id,
        where: a.token_hash == ^hash and a.status == "pending",
        select: {a, t},
        lock: "FOR UPDATE"
      )
    )
  end

  defp lookup_any_action(hash) do
    Repo.one(from(a in AgentDecisionAction, where: a.token_hash == ^hash))
  end

  defp expired?(%AgentApprovalTask{expires_at: nil}), do: false

  defp expired?(%AgentApprovalTask{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) != :lt
  end

  defp authorized_responder?(%AgentApprovalTask{chat_id: chat_id}, user_id) do
    case Repo.get(User, user_id) do
      %User{is_agent: true} -> false
      %User{} -> Chat.is_participant?(chat_id, user_id)
      _ -> false
    end
  end

  defp claim_action!(%AgentApprovalTask{action_mode: "single"} = task, action, user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {task_count, _} =
      from(t in AgentApprovalTask,
        where: t.id == ^task.id and t.status == "pending"
      )
      |> Repo.update_all(
        set: [
          status: "approved",
          chosen_action_id: action.action_id,
          approved_by_user_id: user_id,
          decided_at: now,
          updated_at: now
        ]
      )

    if task_count == 0 do
      {:error, :already_decided}
    else
      {action_count, _} =
        from(a in AgentDecisionAction,
          where: a.id == ^action.id and a.status == "pending"
        )
        |> Repo.update_all(
          set: [
            status: "chosen",
            chosen_by_user_id: user_id,
            chosen_at: now,
            updated_at: now
          ]
        )

      if action_count == 0 do
        {:error, :already_decided}
      else
        _ =
          from(a in AgentDecisionAction,
            where: a.task_id == ^task.id and a.id != ^action.id and a.status == "pending"
          )
          |> Repo.update_all(set: [status: "superseded", updated_at: now])

        updated_task = Repo.get!(AgentApprovalTask, task.id)
        updated_action = Repo.get!(AgentDecisionAction, action.id)
        actor = Repo.get(User, user_id)

        {:ok,
         %{
           task: updated_task,
           action: updated_action,
           actor: actor,
           mode: "single"
         }}
      end
    end
  end

  defp claim_action!(%AgentApprovalTask{action_mode: "multi"} = task, action, user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {action_count, _} =
      from(a in AgentDecisionAction,
        where: a.id == ^action.id and a.status == "pending"
      )
      |> Repo.update_all(
        set: [
          status: "chosen",
          chosen_by_user_id: user_id,
          chosen_at: now,
          updated_at: now
        ]
      )

    if action_count == 0 do
      {:error, :already_decided}
    else
      updated_action = Repo.get!(AgentDecisionAction, action.id)
      actor = Repo.get(User, user_id)

      {:ok,
       %{
         task: task,
         action: updated_action,
         actor: actor,
         mode: "multi"
       }}
    end
  end

  defp claim_action!(_task, _action, _user_id), do: {:error, :invalid_action_mode}

  defp expire_task_by_id(task_id) do
    case Repo.get(AgentApprovalTask, task_id) do
      %AgentApprovalTask{status: "pending"} = task ->
        result = expire_task!(task)
        _ = settle_expired_message(result)
        {:ok, result}

      _ ->
        {:error, :not_pending}
    end
  end

  defp expire_task!(%AgentApprovalTask{} = task) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(t in AgentApprovalTask,
        where: t.id == ^task.id and t.status == "pending"
      )
      |> Repo.update_all(set: [status: "expired", decided_at: now, updated_at: now])

    if count > 0 do
      _ =
        from(a in AgentDecisionAction,
          where: a.task_id == ^task.id and a.status == "pending"
        )
        |> Repo.update_all(set: [status: "expired", updated_at: now])

      %{task: Repo.get!(AgentApprovalTask, task.id), expired: true}
    else
      %{task: Repo.get!(AgentApprovalTask, task.id), expired: false}
    end
  end

  defp maybe_dispatch_callback(%{
         task: %{requested_action: %{"actionType" => "runtime_decision"}} = task,
         action: action,
         actor: actor
       }) do
    run_id = task.requested_action["runId"]
    decision_id = task.requested_action["decisionId"]
    kind = task.requested_action["kind"] || "approval"

    outcome =
      case action.action_id do
        id when id in ["approve", "allow_once", "allow_run"] -> "approve"
        id when id in ["reject", "deny"] -> "reject"
        _ -> action.action_id
      end

    outcome =
      cond do
        kind == "permission" and action.action_id in ["allow_once", "allow_run"] -> "grant"
        kind == "permission" and action.action_id in ["reject", "deny"] -> "deny"
        true -> outcome
      end

    if outcome == "approve_always", do: persist_always_allow(task)

    AgentGateway.decision(run_id, %{
      decisionId: decision_id,
      kind: kind,
      outcome: outcome,
      actionId: action.action_id,
      actorUserId: actor && actor.id
    })
  end

  defp persist_always_allow(%{agent_id: agent_id, requested_action: requested}) do
    tool = requested["tool"]

    with true <- is_binary(tool) and tool != "",
         %Agent{} = agent <- Repo.get(Agent, agent_id) do
      rules = agent.approval_rules || %{}
      allow = (rules["allow"] || []) |> List.wrap() |> Enum.map(&to_string/1)

      if tool in allow do
        :ok
      else
        agent
        |> Agent.changeset(%{approval_rules: Map.put(rules, "allow", allow ++ [tool])})
        |> Repo.update()
      end
    else
      _ -> :ok
    end
  end

  defp maybe_dispatch_callback(%{task: task, action: action, actor: actor}) do
    agent = Repo.get(Agent, task.agent_id) |> Repo.preload(:agent_user)
    event = task.event_id && Repo.get(AgentEvent, task.event_id)
    thread = task.thread_id && Repo.get(AgentEventThread, task.thread_id)

    event_payload =
      case event do
        %AgentEvent{payload: payload} when is_map(payload) -> payload
        _ -> %{}
      end

    body = %{
      "type" => "decision.action",
      "taskId" => task.id,
      "eventId" => task.event_id,
      "sourceEventId" => event && event.event_id,
      "threadId" => task.thread_id,
      "threadKey" => thread && thread.thread_key,
      "eventType" => event && event.event_type,
      "source" => event && event.source,
      "title" => event && event.title,
      "data" => event_payload,
      "actionId" => action.action_id,
      "actionLabel" => action.label,
      "actionMode" => task.action_mode,
      "decidedByUserId" => actor && actor.id,
      "decidedByUsername" => actor && actor.username,
      "decidedAt" =>
        (action.chosen_at || DateTime.utc_now())
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601(),
      "chatId" => task.chat_id
    }

    invocation_event_id =
      "decision:#{task.id}:#{action.action_id}:#{System.unique_integer([:positive])}"

    case Agents.record_invocation(agent, %{
           source: "decision.action",
           vibe_chat_id: task.chat_id,
           event_id: invocation_event_id,
           request_payload: body,
           response_payload: %{},
           status: "completed"
         }) do
      {:ok, invocation} ->
        case Agents.create_delivery_event(agent, invocation, "decision.action", body) do
          {:ok, delivery} -> {:ok, delivery}
          {:error, :missing_callback} -> {:ok, :no_callback}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("[AgentDecisions] failed to record invocation: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      Logger.warning("[AgentDecisions] callback dispatch failed: #{inspect(error)}")
      {:error, error}
  end

  defp maybe_dispatch_callback(_), do: :ok

  defp settle_message(%{task: task, action: action, actor: actor, mode: mode}) do
    if is_binary(task.message_id) do
      actor_name = display_name(actor)
      fallback = "#{action.label} · #{actor_name}"
      decision = settled_decision_payload(task, action, actor, mode)

      {status, text, parts} =
        if mode == "single" or decision["actions"] == [] do
          {"decided", fallback,
           [
             %{
               "type" => "template",
               "key" => "decision.chosen",
               "args" => %{
                 "actionId" => action.action_id,
                 "actionLabel" => action.label,
                 "actorName" => actor_name,
                 "actorUserId" => actor && actor.id
               }
             }
           ]}
        else
          existing_text = existing_service_text(task) || fallback

          {"pending", existing_text,
           [
             %{
               "type" => "template",
               "key" => "decision.partial",
               "args" => %{
                 "actionId" => action.action_id,
                 "actionLabel" => action.label,
                 "actorName" => actor_name,
                 "actorUserId" => actor && actor.id
               }
             }
           ]}
        end

      service =
        service_node(%{
          kind: "decision",
          text: text,
          status: status,
          parts: parts,
          decision: decision
        })

      update_service_message(task, service, text)
    else
      :ok
    end
  end

  defp settle_message(_), do: :ok

  defp settle_expired_message(%{task: task, expired: true}) do
    if is_binary(task.message_id) do
      fallback = "Decision expired"

      service =
        service_node(%{
          kind: "decision",
          text: fallback,
          status: "expired",
          parts: [
            %{"type" => "template", "key" => "decision.expired", "args" => %{}}
          ],
          decision: %{
            "taskId" => task.id,
            "actionMode" => task.action_mode,
            "expiresAt" => task.expires_at && DateTime.to_iso8601(task.expires_at),
            "actions" => [],
            "chosen" => nil,
            "status" => "expired"
          }
        })

      update_service_message(task, service, fallback)
    else
      :ok
    end
  end

  defp settle_expired_message(_), do: :ok

  defp settled_decision_payload(task, action, actor, mode) do
    remaining =
      if mode == "multi" do
        previous_actions = existing_client_actions(task)

        previous_actions
        |> Enum.reject(fn item ->
          (item["id"] || item[:id]) == action.action_id
        end)
      else
        []
      end

    %{
      "taskId" => task.id,
      "actionMode" => task.action_mode,
      "expiresAt" => task.expires_at && DateTime.to_iso8601(task.expires_at),
      "actions" => remaining,
      "status" =>
        cond do
          mode == "single" -> "decided"
          remaining == [] -> "decided"
          true -> "partial"
        end,
      "chosen" => %{
        "actionId" => action.action_id,
        "actionLabel" => action.label,
        "byUserId" => actor && actor.id,
        "byName" => display_name(actor),
        "at" =>
          (action.chosen_at || DateTime.utc_now())
          |> DateTime.truncate(:second)
          |> DateTime.to_iso8601()
      }
    }
  end

  defp existing_client_actions(%AgentApprovalTask{} = task) do
    case load_task_message(task) do
      %Message{metadata: metadata} when is_map(metadata) ->
        get_in(metadata, [@service_key, "decision", "actions"]) |> List.wrap()

      _ ->
        []
    end
  end

  defp existing_service_text(%AgentApprovalTask{} = task) do
    case load_task_message(task) do
      %Message{metadata: metadata} when is_map(metadata) ->
        get_in(metadata, [@service_key, "text"])

      _ ->
        nil
    end
  end

  defp load_task_message(%AgentApprovalTask{message_id: message_id, chat_id: chat_id})
       when is_binary(message_id) do
    case Ecto.UUID.cast(message_id) do
      {:ok, uuid} ->
        Repo.one(from(m in Message, where: m.id == ^uuid and m.chat_id == ^chat_id))

      _ ->
        nil
    end
  end

  defp load_task_message(_), do: nil

  defp update_service_message(%AgentApprovalTask{} = task, service, body) do
    agent = Repo.get(Agent, task.agent_id)

    if agent do
      RepoRLS.with_user(agent.agent_user_id, fn ->
        with {:ok, uuid} <- Ecto.UUID.cast(task.message_id),
             %Message{} = message <-
               Repo.one(from(m in Message, where: m.id == ^uuid and m.chat_id == ^task.chat_id)) do
          metadata =
            (message.metadata || %{})
            |> Map.put(@service_key, service)
            |> Map.put("text", body)
            |> Map.put("status", service["status"])

          encrypted = AgentMessageCrypto.encrypt_for_storage(body || "")
          edited_at = System.system_time(:millisecond)

          case message
               |> Message.changeset(%{
                 encrypted_content: encrypted,
                 metadata: metadata,
                 timestamp: max(message.timestamp || 0, edited_at)
               })
               |> Repo.update() do
            {:ok, updated} ->
              mutation_payload = %{
                chatId: task.chat_id,
                messageId: updated.id,
                encryptedContent: body || "",
                editedAt: edited_at,
                editedBy: agent.agent_user_id,
                plainContent: body,
                plaintext: body,
                metadata: metadata,
                type: updated.type,
                message:
                  updated
                  |> Chat.client_message_payload()
                  |> Chat.mirrored_message_payload()
              }

              VibeWeb.Endpoint.broadcast!(
                "chat:#{task.chat_id}",
                "message-edited",
                mutation_payload
              )

              Chat.broadcast_user_chat_event(
                task.chat_id,
                "message-edited",
                mutation_payload
              )

              :ok

            error ->
              error
          end
        else
          _ -> :ok
        end
      end)
    else
      :ok
    end
  end

  defp display_name(%User{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%User{username: username}) when is_binary(username), do: username
  defp display_name(_), do: "Someone"
end
