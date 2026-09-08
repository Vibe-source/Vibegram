defmodule Vibe.AI.AgentEventRuntime do
  @moduledoc """
  Event-inbox runtime for provider agent events, including progressive `message.stream`
  delivery.
  """

  import Ecto.Query, warn: false
  import Plug.Crypto, only: [secure_compare: 2]

  require Logger

  alias Decimal, as: D
  alias Vibe.Agent
  alias Vibe.AgentApprovalTask
  alias Vibe.AgentEvent
  alias Vibe.AgentEventThread
  alias Vibe.AgentIntegration
  alias Vibe.AgentRun
  alias Vibe.AgentRunbook
  alias Vibe.Agents
  alias Vibe.AI.AgentDecisions
  alias Vibe.Chat
  alias Vibe.Chat.AgentMessageCrypto
  alias Vibe.Chat.Message
  alias Vibe.Notifications
  alias Vibe.ProviderContent
  alias Vibe.Repo
  alias Vibe.RepoRLS

  @safe_action_types ~w[post_message post_checklist request_confirmation set_thread_status]
  @high_priority_keywords ~w[failed failure blocked fraud urgent escalated chargeback liquidation stop_loss]
  @batch_summary_event_line_limit 12
  @stream_table :vibe_agent_event_streams
  @stream_event_type "message.stream"
  @max_event_params_bytes 512 * 1024
  @max_stream_params_bytes 256 * 1024
  @max_rich_text_chars 32_000
  @max_attachment_count 10
  @max_attachment_url_chars 2_048

  def ingest(%Agent{} = agent, params, opts \\ []) when is_map(params) do
    secret = Keyword.get(opts, :secret)
    event_type = normalize_string(params["eventType"] || params["event_type"])

    Logger.info(
      "[InboxBanner] ingest agent_id=#{inspect(agent.id)} " <>
        "raw_approval_rules_event_inbox=#{inspect(get_in(agent.approval_rules || %{}, ["event_inbox"]))} " <>
        "params_event_type=#{inspect(event_type)}"
    )

    with {:ok, integration} <- resolve_integration(agent, params, secret) do
      if event_type == @stream_event_type do
        handle_message_stream(agent, integration, params)
      else
        with {:ok, normalized} <- normalize_event(agent, integration, params),
             :ok <- ensure_destination_chat(agent, normalized.destination_chat_id),
             :ok <- ensure_event_trigger(agent, normalized.destination_chat_id),
             {:ok, result} <- persist_event(agent, integration, normalized) do
          Logger.info(
            "[InboxBanner] ingest result agent_id=#{inspect(agent.id)} " <>
              "decision=#{inspect(Map.get(result, :decision))} " <>
              "messagePosted=#{inspect(Map.get(result, :messagePosted))} " <>
              "status=#{inspect(Map.get(result, :status))}"
          )

          {:ok, result}
        end
      end
    end
  end

  # ── message.stream pure helpers (public for unit tests; no DB) ─────────────

  @doc """
  Normalize a `message.stream` params map into a frame struct.
  """
  def normalize_stream_params(params) when is_map(params) do
    stream_id = normalize_string(params["streamId"] || params["stream_id"])
    seq = normalize_integer(params["seq"])
    text = normalize_rich_text(params["text"] || params["message"]) || ""

    content =
      cond do
        is_map(params["content"]) -> params["content"]
        is_map(params["providerContent"]) -> params["providerContent"]
        true -> nil
      end

    done = normalize_boolean(params["done"]) == true

    destination_chat_id =
      normalize_string(params["destinationChatId"] || params["destination_chat_id"])

    cond do
      not json_size_within?(params, @max_stream_params_bytes) ->
        {:error, :stream_payload_too_large}

      is_nil(stream_id) ->
        {:error, :missing_stream_id}

      is_nil(seq) ->
        {:error, :missing_seq}

      true ->
        {:ok,
         %{
           stream_id: stream_id,
           seq: seq,
           text: text,
           content: content,
           done: done,
           destination_chat_id: destination_chat_id
         }}
    end
  end

  def normalize_stream_params(_), do: {:error, :missing_stream_id}

  @doc """
  Pure stream-frame state machine.
  """
  def stream_frame_decision(nil, %{seq: seq, done: false} = frame) when is_integer(seq) do
    {:create, %{message_id: nil, last_seq: seq, done: false}, frame}
  end

  def stream_frame_decision(nil, %{seq: seq, done: true} = frame) when is_integer(seq) do
    {:create_finalize, %{message_id: nil, last_seq: seq, done: true}, frame}
  end

  def stream_frame_decision(%{done: true}, _frame) do
    {:ignore, :stream_done}
  end

  def stream_frame_decision(%{last_seq: last_seq}, %{seq: seq})
      when is_integer(last_seq) and is_integer(seq) and seq <= last_seq do
    {:ignore, :stale_seq}
  end

  def stream_frame_decision(%{} = state, %{seq: seq, done: false} = frame)
      when is_integer(seq) do
    {:update, %{state | last_seq: seq, done: false}, frame}
  end

  def stream_frame_decision(%{} = state, %{seq: seq, done: true} = frame)
      when is_integer(seq) do
    {:finalize, %{state | last_seq: seq, done: true}, frame}
  end

  def stream_frame_decision(_state, _frame), do: {:ignore, :invalid_frame}

  @doc """
  Pure final-frame content handling.
  """
  def finalize_stream_content(text, nil) when is_binary(text), do: {:ok, text, nil}

  def finalize_stream_content(text, content) when is_binary(text) and is_map(content) do
    case ProviderContent.parse(content) do
      {:ok, normalized} ->
        attrs = ProviderContent.to_message_attrs(normalized)
        body = normalize_string(attrs["text"]) || text
        {:ok, body, normalized}

      {:error, reason} ->
        {:error, {:invalid_content, reason}, text}
    end
  end

  def finalize_stream_content(text, _) when is_binary(text), do: {:ok, text, nil}

  def finalize_stream_content(text, content) do
    finalize_stream_content(to_string(text || ""), content)
  end

  @doc """
  Normalizes event attachments from both the legacy top-level field and the
  provider event payload's `data.attachments` field.
  """
  def normalize_event_attachments(params) when is_map(params) do
    payload = params["data"] || params["payload"] || %{}

    List.wrap(params["attachments"])
    |> Kernel.++(List.wrap(payload["attachments"] || payload[:attachments]))
    |> normalize_attachments()
  end

  def normalize_event_attachments(_), do: %{"items" => []}


  defp handle_message_stream(%Agent{} = agent, integration, params) do
    ensure_stream_table!()

    with {:ok, frame0} <- normalize_stream_params(params),
         {:ok, frame} <- resolve_stream_destination(frame0, agent, integration),
         :ok <- ensure_destination_chat(agent, frame.destination_chat_id),
         :ok <- ensure_event_trigger(agent, frame.destination_chat_id) do
      key = stream_state_key(agent.id, frame.stream_id)
      state = stream_lookup(key)
      decision = stream_frame_decision(state, frame)

      case decision do
        {:ignore, reason} ->
          {:ok,
           %{
             success: true,
             ignored: true,
             reason: reason,
             streamId: frame.stream_id,
             seq: frame.seq,
             messageId: state && state.message_id,
             done: frame.done
           }}

        {:create, next_state, frame} ->
          apply_stream_create(agent, key, next_state, frame, streaming?: true)

        {:update, next_state, frame} ->
          apply_stream_update(agent, key, state, next_state, frame, finalize?: false)

        {:finalize, next_state, frame} ->
          apply_stream_update(agent, key, state, next_state, frame, finalize?: true)

        {:create_finalize, next_state, frame} ->
          apply_stream_create(agent, key, next_state, frame, streaming?: false, finalize?: true)
      end
    end
  end

  defp resolve_stream_destination(frame, agent, integration) do
    dest =
      frame.destination_chat_id ||
        (integration && integration.default_destination_chat_id) ||
        agent.default_destination_chat_id ||
        owner_dm_chat_id(agent)

    case normalize_string(dest) do
      nil -> {:error, :missing_destination_chat}
      chat_id -> {:ok, %{frame | destination_chat_id: chat_id}}
    end
  end

  defp apply_stream_create(agent, key, next_state, frame, opts) do
    streaming? = Keyword.get(opts, :streaming?, true)
    finalize? = Keyword.get(opts, :finalize?, false)

    {text, content_meta, content_error} =
      if finalize? do
        case finalize_stream_content(frame.text, frame.content) do
          {:ok, body, meta} -> {body, meta, nil}
          {:error, err, body} -> {body, nil, err}
        end
      else
        {frame.text, nil, nil}
      end

    metadata =
      stream_message_metadata(agent, streaming?: streaming? and not finalize?)
      |> maybe_put_content(content_meta)

    case post_chat_message(agent, frame.destination_chat_id, text, metadata, nil) do
      {:ok, %{message_id: message_id} = posted} ->
        stored = %{next_state | message_id: message_id}
        stream_put(key, stored)

        result = %{
          success: true,
          ignored: false,
          streamId: frame.stream_id,
          seq: frame.seq,
          messageId: message_id,
          messagePosted: true,
          done: frame.done,
          timestamp: posted.timestamp
        }

        if content_error, do: {:error, content_error}, else: {:ok, result}

      error ->
        error
    end
  end

  defp apply_stream_update(agent, key, state, next_state, frame, opts) do
    finalize? = Keyword.get(opts, :finalize?, false)
    message_id = state.message_id

    if not is_binary(message_id) do
      {:error, :stream_message_missing}
    else
      {text, content_meta, content_error} =
        if finalize? do
          case finalize_stream_content(frame.text, frame.content) do
            {:ok, body, meta} -> {body, meta, nil}
            {:error, err, body} -> {body, nil, err}
          end
        else
          {frame.text, nil, nil}
        end

      edited_at = System.system_time(:millisecond)

      case update_stream_message(
             agent,
             frame.destination_chat_id,
             message_id,
             text,
             streaming?: not finalize?,
             content: content_meta,
             edited_at: edited_at
           ) do
        {:ok, message} ->
          stream_put(key, %{next_state | message_id: message_id})

          broadcast_stream_edited(
            agent,
            frame.destination_chat_id,
            message_id,
            text,
            edited_at,
            message
          )

          result = %{
            success: true,
            ignored: false,
            streamId: frame.stream_id,
            seq: frame.seq,
            messageId: message_id,
            messagePosted: true,
            done: frame.done,
            editedAt: edited_at
          }

          if content_error, do: {:error, content_error}, else: {:ok, result}

        error ->
          error
      end
    end
  end

  defp stream_message_metadata(agent, opts) do
    streaming? = Keyword.get(opts, :streaming?, false)

    agent_username =
      case agent.agent_user do
        %{username: username} when is_binary(username) -> username
        _ -> nil
      end

    %{
      "isAgentMessage" => true,
      "agentName" => agent.display_name,
      "agentId" => agent.id,
      "agentUserId" => agent.agent_user_id,
      "agentUsername" => agent_username,
      "agentHandle" => if(agent_username, do: "@#{agent_username}", else: nil),
      "streaming" => streaming?,
      "eventType" => @stream_event_type
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> then(fn meta ->
      if streaming?, do: meta, else: Map.delete(meta, "streaming")
    end)
  end

  defp maybe_put_content(metadata, nil), do: metadata

  defp maybe_put_content(metadata, content) when is_map(content),
    do: Map.put(metadata, "content", content)

  defp update_stream_message(agent, chat_id, message_id, text, opts) do
    streaming? = Keyword.get(opts, :streaming?, false)
    content = Keyword.get(opts, :content)
    edited_at = Keyword.get(opts, :edited_at) || System.system_time(:millisecond)
    encrypted = AgentMessageCrypto.encrypt_for_storage(text || "")

    RepoRLS.with_user(agent.agent_user_id, fn ->
      with {:ok, uuid} <- Ecto.UUID.cast(message_id),
           %Message{} = message <-
             Repo.one(from(m in Message, where: m.id == ^uuid and m.chat_id == ^chat_id)),
           true <- message.from_id == agent.agent_user_id do
        metadata =
          (message.metadata || %{})
          |> Map.merge(%{
            "isAgentMessage" => true,
            "agentName" => agent.display_name,
            "agentId" => agent.id,
            "agentUserId" => agent.agent_user_id
          })
          |> then(fn meta ->
            if streaming? do
              Map.put(meta, "streaming", true)
            else
              Map.delete(meta, "streaming")
            end
          end)
          |> maybe_put_content(content)

        next_ts = max(message.timestamp || 0, edited_at)

        message
        |> Message.changeset(%{
          encrypted_content: encrypted,
          metadata: metadata,
          timestamp: next_ts
        })
        |> Repo.update()
      else
        :error -> {:error, :invalid_id}
        nil -> {:error, :not_found}
        false -> {:error, :forbidden}
      end
    end)
  end

  defp broadcast_stream_edited(agent, chat_id, message_id, plain_text, edited_at, message) do
    payload = %{
      chatId: chat_id,
      messageId: message_id,
      encryptedContent: plain_text || "",
      editedAt: edited_at,
      editedBy: agent.agent_user_id,
      plainContent: plain_text,
      plaintext: plain_text,
      message:
        message
        |> Chat.client_message_payload()
        |> Chat.mirrored_message_payload()
    }

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message-edited", payload)
    Chat.broadcast_user_chat_event(chat_id, "message-edited", payload)
  end

  defp stream_state_key(agent_id, stream_id), do: {agent_id, stream_id}

  defp ensure_stream_table! do
    case :ets.whereis(@stream_table) do
      :undefined ->
        try do
          :ets.new(@stream_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end

  defp stream_lookup(key) do
    case :ets.lookup(@stream_table, key) do
      [{^key, state}] -> state
      _ -> nil
    end
  end

  defp stream_put(key, state) do
    true = :ets.insert(@stream_table, {key, state})
    :ok
  end

  def execute_approved_task(%Agent{} = agent, %AgentApprovalTask{} = task) do
    with %AgentEventThread{} = thread <- Repo.get(AgentEventThread, task.thread_id),
         {:ok, payload} <-
           execute_requested_action(
             agent,
             thread,
             task.requested_action || %{},
             thread.root_message_id
           ),
         {:ok, _thread} <-
           thread
           |> AgentEventThread.changeset(%{
             status: Map.get(payload, :thread_status, thread.status),
             last_decision: "approved_action"
           })
           |> Repo.update() do
      {:ok, payload}
    else
      nil -> {:error, :thread_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_event(%Agent{} = agent, integration, normalized) do
    existing =
      Repo.one(
        from(e in AgentEvent,
          where:
            e.agent_id == ^agent.id and
              e.source == ^normalized.source and
              e.event_id == ^normalized.event_id,
          preload: [:thread]
        )
      )

    case existing do
      %AgentEvent{} = event ->
        {:ok,
         %{
           success: true,
           duplicate: true,
           threadId: event.thread_id,
           eventId: event.id,
           decision: event.decision || "duplicate",
           status: event.status
         }}

      nil ->
        Repo.transaction(fn ->
          thread =
            upsert_thread!(
              agent,
              integration,
              normalized.source,
              normalized.thread_key,
              normalized.destination_chat_id,
              normalized.title,
              normalized.payload,
              normalized.occurred_at
            )

          last_event = latest_thread_event(thread.id)
          runbook = matching_runbook(agent, integration, normalized.event_type)
          policy = evaluate_policy(agent, integration, normalized, last_event, runbook)
          inbox_config = event_inbox_config(agent, integration)

          Logger.info(
            "[InboxBanner] persist agent_id=#{inspect(agent.id)} " <>
              "inbox_mode=#{inspect(inbox_config.mode)} window_hours=#{inspect(inbox_config.summary_window_hours)} " <>
              "policy_mode=#{inspect(policy.mode)} post_event_message?=#{inspect(policy.post_event_message?)} " <>
              "post_individual?=#{inspect(post_individual_event_message?(policy, inbox_config))}"
          )

          event =
            %AgentEvent{}
            |> AgentEvent.changeset(%{
              agent_id: agent.id,
              integration_id: integration && integration.id,
              thread_id: thread.id,
              event_id: normalized.event_id,
              event_type: normalized.event_type,
              source: normalized.source,
              title: normalized.title,
              text: normalized.text,
              attachments: normalized.attachments,
              payload: normalized.payload,
              occurred_at: normalized.occurred_at,
              status: initial_event_status(policy.mode),
              decision: policy.mode,
              decision_reason: policy.reason
            })
            |> Repo.insert!()

          {thread, event, message_payload} =
            case policy.post_event_message? or attachment_items?(normalized.attachments) do
              true ->
                silent? = not post_individual_event_message?(policy, inbox_config)

                {:ok, message_payload} =
                  post_event_message(agent, thread, event, normalized, policy, silent?)

                updated_event =
                  event
                  |> AgentEvent.changeset(%{message_id: message_payload.message_id})
                  |> Repo.update!()

                updated_thread =
                  if is_nil(thread.root_message_id) and not silent? do
                    thread
                    |> AgentEventThread.changeset(%{root_message_id: message_payload.message_id})
                    |> Repo.update!()
                  else
                    thread
                  end

                {updated_thread, updated_event, message_payload}

              false ->
                {thread, event, nil}
            end

          summary = build_summary(thread.summary, normalized, policy)

          {current_state, batch_summary_since} =
            thread.current_state
            |> Kernel.||(%{})
            |> next_thread_state(normalized, policy)
            |> apply_event_inbox_state(normalized.occurred_at, policy, inbox_config)

          updated_thread =
            thread
            |> AgentEventThread.changeset(%{
              title: normalized.title || thread.title,
              summary: summary,
              current_state: current_state,
              priority: policy.priority,
              last_decision: policy.mode,
              latest_event_at: normalized.occurred_at
            })
            |> Repo.update!()

          {updated_thread, batch_summary_payload} =
            case maybe_post_batched_summary(
                   agent,
                   updated_thread,
                   batch_summary_since,
                   normalized.occurred_at,
                   inbox_config
                 ) do
              {:ok, next_thread, summary_payload} -> {next_thread, summary_payload}
              {:error, reason} -> Repo.rollback(reason)
            end

          result =
            case policy.mode do
              "act" ->
                execute_runbook(
                  agent,
                  integration,
                  updated_thread,
                  event,
                  runbook,
                  normalized,
                  policy
                )

              "approval_required" ->
                create_approval(
                  agent,
                  integration,
                  updated_thread,
                  event,
                  runbook,
                  normalized,
                  policy
                )

              _ ->
                {:ok,
                 %{
                   status: initial_event_status(policy.mode),
                   run:
                     create_run!(agent, integration, updated_thread, event, runbook, policy, %{}),
                   message: batch_summary_payload || message_payload
                 }}
            end

          integration && touch_integration!(integration)

          case result do
            {:ok, details} ->
              %{
                success: true,
                duplicate: false,
                threadId: updated_thread.id,
                eventId: event.id,
                decision: policy.mode,
                priority: policy.priority,
                status: details.status || initial_event_status(policy.mode),
                messagePosted: message_payload != nil or batch_summary_payload != nil,
                rootMessageId: updated_thread.root_message_id,
                runId: details.run && details.run.id,
                approvalTaskId: details[:approval_task] && details.approval_task.id
              }

            {:error, reason} ->
              {:runtime_error, reason}
          end
        end)
        |> case do
          {:ok, {:runtime_error, reason}} -> {:error, reason}
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp resolve_integration(%Agent{} = agent, params, secret) do
    requested_id = normalize_string(params["integrationId"] || params["integration_id"])

    integration =
      case requested_id do
        nil -> nil
        integration_id -> Agents.get_integration(agent, integration_id)
      end

    cond do
      not is_binary(secret) ->
        {:error, :invalid_secret}

      match?(%AgentIntegration{}, integration) and verify_integration_secret(integration, secret) ->
        {:ok, integration}

      match?(%AgentIntegration{}, integration) and Agents.verify_secret(agent, secret) ->
        {:ok, integration}

      match?(%AgentIntegration{}, integration) ->
        {:error, :invalid_secret}

      matched = Agents.find_integration_by_secret(agent, secret) ->
        {:ok, matched}

      Agents.verify_secret(agent, secret) ->
        {:ok, nil}

      true ->
        {:error, :invalid_secret}
    end
  end

  defp normalize_event(%Agent{} = agent, integration, params) do
    event_type = normalize_string(params["eventType"] || params["event_type"])

    source =
      normalize_string(params["source"]) || (integration && integration.source_type) || "internal"

    title = normalize_rich_text(params["title"])
    text = normalize_rich_text(params["text"] || params["message"] || params["body"])
    payload = normalize_payload(params["data"] || params["payload"])
    occurred_at = parse_datetime(params["timestamp"]) || DateTime.utc_now()

    event_id =
      normalize_string(params["eventId"] || params["event_id"]) ||
        build_fingerprint(source, title, text, occurred_at, payload)

    thread_key =
      normalize_string(params["threadKey"] || params["thread_key"]) ||
        normalize_string(payload["thread_key"]) ||
        normalize_string(payload["order_id"]) ||
        normalize_string(payload["trade_id"]) ||
        event_id

    destination_chat_id =
      normalize_string(params["destinationChatId"] || params["destination_chat_id"]) ||
        (integration && integration.default_destination_chat_id) ||
        agent.default_destination_chat_id ||
        owner_dm_chat_id(agent)

    _ignored_callback = params["callbackUrl"] || params["callback_url"]

    with :ok <- validate_event_params_size(params),
         {:ok, declaration} <- AgentDecisions.normalize_declaration(params) do
      cond do
        is_nil(event_type) ->
          {:error, :missing_event_type}

        is_nil(destination_chat_id) ->
          {:error, :missing_destination_chat}

        true ->
          {:ok,
           %{
             event_id: event_id,
             event_type: event_type,
             source: source,
             title: title || humanize_event_type(event_type),
             text: text,
             payload: payload,
             attachments: normalize_event_attachments(params),
             occurred_at: occurred_at,
             thread_key: thread_key,
             destination_chat_id: destination_chat_id,
             declaration: declaration
           }}
      end
    end
  end

  defp owner_dm_chat_id(%Agent{owner_user_id: owner, agent_user_id: agent_user})
       when is_binary(owner) and is_binary(agent_user) do
    case Chat.ensure_dm_chat(owner, agent_user) do
      {:ok, chat_id, _status} -> chat_id
      _ -> nil
    end
  end

  defp owner_dm_chat_id(_agent), do: nil

  defp ensure_destination_chat(%Agent{} = agent, chat_id) do
    if Chat.is_participant?(chat_id, agent.agent_user_id),
      do: :ok,
      else: {:error, :chat_not_attached}
  end

  defp ensure_event_trigger(%Agent{} = agent, chat_id) do
    if Chat.channel_agent_event_enabled?(chat_id, agent),
      do: :ok,
      else: {:error, :event_trigger_not_enabled}
  end

  defp upsert_thread!(
         agent,
         integration,
         source,
         thread_key,
         chat_id,
         title,
         payload,
         occurred_at
       ) do
    existing =
      Repo.one(
        from(t in AgentEventThread,
          where: t.agent_id == ^agent.id and t.source == ^source and t.thread_key == ^thread_key
        )
      )

    attrs = %{
      agent_id: agent.id,
      integration_id: integration && integration.id,
      chat_id: chat_id,
      source: source,
      thread_key: thread_key,
      title: title,
      latest_event_at: occurred_at,
      current_state: payload
    }

    case existing do
      nil ->
        %AgentEventThread{}
        |> AgentEventThread.changeset(attrs)
        |> Repo.insert!()

      %AgentEventThread{} = thread ->
        thread
        |> AgentEventThread.changeset(%{
          integration_id: (integration && integration.id) || thread.integration_id,
          chat_id: chat_id,
          title: title || thread.title,
          latest_event_at: occurred_at
        })
        |> Repo.update!()
    end
  end

  defp latest_thread_event(thread_id) do
    Repo.one(
      from(e in AgentEvent,
        where: e.thread_id == ^thread_id,
        order_by: [desc: e.occurred_at, desc: e.inserted_at],
        limit: 1
      )
    )
  end

  defp evaluate_policy(agent, integration, normalized, last_event, runbook) do
    priority = classify_priority(normalized)
    autonomy = effective_autonomy(agent, integration)
    estimated_cost_cents = estimated_cost_cents(runbook)
    declaration = Map.get(normalized, :declaration)

    cond do
      not event_type_enabled?(agent, integration, normalized.event_type) ->
        %{
          mode: "log_only",
          priority: priority,
          reason: "event_type_disabled",
          post_event_message?: false,
          estimated_cost_cents: 0
        }

      noise_duplicate?(normalized, last_event) ->
        %{
          mode: "log_only",
          priority: priority,
          reason: "noise_suppressed",
          post_event_message?: false,
          estimated_cost_cents: 0
        }

      match?(%{actions: [_ | _]}, declaration) ->
        %{
          mode: "approval_required",
          priority: priority,
          reason: "sender_declared_actions",
          post_event_message?: true,
          estimated_cost_cents: estimated_cost_cents,
          declaration: declaration
        }

      budget_exceeded?(agent, integration, estimated_cost_cents) ->
        %{
          mode: if(runbook, do: "approval_required", else: "log_only"),
          priority: priority,
          reason: "budget_exceeded",
          post_event_message?: true,
          estimated_cost_cents: estimated_cost_cents
        }

      match?(%AgentRunbook{}, runbook) and auto_executable?(autonomy, runbook) ->
        %{
          mode: "act",
          priority: priority,
          reason: "matching_runbook",
          post_event_message?: true,
          estimated_cost_cents: estimated_cost_cents
        }

      match?(%AgentRunbook{}, runbook) ->
        %{
          mode: "approval_required",
          priority: priority,
          reason: "runbook_requires_approval",
          post_event_message?: true,
          estimated_cost_cents: estimated_cost_cents
        }

      true ->
        %{
          mode: "summarize",
          priority: priority,
          reason: "summary_only",
          post_event_message?: true,
          estimated_cost_cents: estimated_cost_cents
        }
    end
  end

  defp event_type_enabled?(agent, integration, event_type) do
    integration_enabled = integration && List.wrap(integration.event_types_enabled)
    agent_enabled = List.wrap(agent.event_types_enabled)

    enabled =
      case integration_enabled do
        list when is_list(list) and list != [] -> list
        _ -> agent_enabled
      end

    enabled == [] or event_type in enabled
  end

  defp classify_priority(normalized) do
    searchable =
      [
        normalized.event_type,
        normalized.title,
        normalized.text,
        inspect(normalized.payload)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      Enum.any?(@high_priority_keywords, &String.contains?(searchable, &1)) -> "urgent"
      String.contains?(searchable, "refund") or String.contains?(searchable, "failed") -> "high"
      true -> "normal"
    end
  end

  defp effective_autonomy(agent, %AgentIntegration{} = integration),
    do: integration.autonomy_mode || agent.autonomy_mode

  defp effective_autonomy(agent, _integration), do: agent.autonomy_mode || "safe_auto"

  defp auto_executable?(autonomy, %AgentRunbook{} = runbook) do
    runbook.enabled &&
      runbook.action_type in @safe_action_types &&
      case autonomy do
        "full_auto" -> runbook.risk_level in ["low", "medium"]
        "safe_auto" -> runbook.risk_level == "low"
        _ -> false
      end
  end

  defp budget_exceeded?(agent, integration, estimated_cost_cents) do
    daily_budget = (integration && integration.cost_budget_daily) || agent.cost_budget_daily
    monthly_budget = (integration && integration.cost_budget_monthly) || agent.cost_budget_monthly

    cond do
      is_integer(daily_budget) and daily_budget >= 0 and
          today_cost_cents(agent, integration) + estimated_cost_cents > daily_budget ->
        true

      is_integer(monthly_budget) and monthly_budget >= 0 and
          month_cost_cents(agent, integration) + estimated_cost_cents > monthly_budget ->
        true

      true ->
        false
    end
  end

  defp today_cost_cents(agent, integration) do
    since = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    run_cost_cents(agent, integration, since)
  end

  defp month_cost_cents(agent, integration) do
    today = Date.utc_today()
    since = Date.new!(today.year, today.month, 1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    run_cost_cents(agent, integration, since)
  end

  defp run_cost_cents(agent, integration, since) do
    integration_id = integration && integration.id

    query =
      from(r in AgentRun,
        where: r.agent_id == ^agent.id and r.inserted_at >= ^since,
        select: r.cost_usd
      )

    query =
      if is_binary(integration_id) do
        from(r in query, where: r.integration_id == ^integration_id)
      else
        query
      end

    Repo.all(query)
    |> Enum.reduce(0, fn
      %D{} = amount, acc ->
        cents =
          amount
          |> D.mult(D.new(100))
          |> D.round(0)
          |> D.to_string()
          |> String.to_integer()

        acc + cents

      _amount, acc ->
        acc
    end)
  end

  defp estimated_cost_cents(nil), do: 1
  defp estimated_cost_cents(%AgentRunbook{action_type: "post_message"}), do: 3
  defp estimated_cost_cents(%AgentRunbook{action_type: "request_confirmation"}), do: 3
  defp estimated_cost_cents(%AgentRunbook{}), do: 5

  defp build_summary(_previous_summary, normalized, policy) do
    latest =
      compact_event_summary_line(normalized) ||
        "#{humanize_event_type(normalized.event_type)} in #{normalized.thread_key}"

    "[#{String.upcase(policy.priority)}] #{latest}"
  end

  defp next_thread_state(current_state, normalized, policy) do
    current_state
    |> Map.merge(normalized.payload)
    |> Map.put("last_event_type", normalized.event_type)
    |> Map.put("last_event_text", normalized.text)
    |> Map.put("last_event_title", normalized.title)
    |> Map.put("last_event_summary", compact_event_summary_line(normalized))
    |> Map.put("last_event_at", DateTime.to_iso8601(normalized.occurred_at))
    |> Map.put("priority", policy.priority)
  end

  defp event_inbox_config(%Agent{} = agent, %AgentIntegration{} = integration) do
    merged =
      get_in(integration.routing_rules || %{}, ["event_inbox"]) ||
        get_in(agent.approval_rules || %{}, ["event_inbox"]) || %{}

    build_event_inbox_config(merged)
  end

  defp event_inbox_config(%Agent{} = agent, _integration) do
    merged = get_in(agent.approval_rules || %{}, ["event_inbox"]) || %{}
    build_event_inbox_config(merged)
  end

  defp build_event_inbox_config(merged) when is_map(merged) do
    %{
      mode: normalize_event_inbox_mode(merged["mode"] || merged[:mode]),
      summary_window_hours:
        normalize_summary_window_hours(
          merged["summary_window_hours"] || merged[:summary_window_hours] || merged["cadence"] ||
            merged[:cadence]
        ),
      schedule:
        normalize_summary_schedule(merged["summary_schedule"] || merged[:summary_schedule]),
      summary_times: normalize_summary_times(merged["summary_times"] || merged[:summary_times])
    }
  end

  defp build_event_inbox_config(_), do: build_event_inbox_config(%{})

  defp normalize_event_inbox_mode(value) do
    case normalize_string(value) do
      "batched" -> "batched_summary"
      "batch" -> "batched_summary"
      "batched_summary" -> "batched_summary"
      "summary" -> "batched_summary"
      "per_event" -> "per_event"
      "default" -> "per_event"
      "live" -> "per_event"
      _ -> "per_event"
    end
  end

  defp normalize_summary_window_hours(value) do
    case normalize_string(value) do
      "4h" ->
        4

      "4" ->
        4

      "daily" ->
        24

      "24h" ->
        24

      "24" ->
        24

      _ ->
        case normalize_integer(value) do
          hours when is_integer(hours) and hours > 0 -> hours
          _ -> 24
        end
    end
  end

  defp normalize_summary_schedule(value) do
    case normalize_string(value) do
      "daily" -> "daily"
      "time_of_day" -> "daily"
      "times" -> "daily"
      "fixed" -> "daily"
      _ -> "interval"
    end
  end

  defp normalize_summary_times(value) do
    value
    |> List.wrap()
    |> Enum.map(&parse_summary_time/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp parse_summary_time(value) when is_integer(value) do
    cond do
      value >= 0 and value <= 23 -> value * 60
      value >= 0 and value < 1440 -> value
      true -> nil
    end
  end

  defp parse_summary_time(value) when is_binary(value) do
    case String.split(String.trim(value), ":", parts: 2) do
      [h, m] ->
        with {hour, _} <- Integer.parse(h),
             {minute, _} <- Integer.parse(m),
             true <- hour in 0..23 and minute in 0..59 do
          hour * 60 + minute
        else
          _ -> nil
        end

      [h] ->
        case Integer.parse(h) do
          {hour, _} when hour in 0..23 -> hour * 60
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_summary_time(_), do: nil

  defp daily_summary_due?(_pending_started_at, _occurred_at, []), do: false

  defp daily_summary_due?(pending_started_at, occurred_at, minutes_list) do
    case last_scheduled_at(occurred_at, minutes_list) do
      nil -> false
      scheduled_at -> DateTime.compare(scheduled_at, pending_started_at) == :gt
    end
  end

  defp last_scheduled_at(now, minutes_list) do
    today = DateTime.to_date(now)

    [today, Date.add(today, -1)]
    |> Enum.flat_map(fn date ->
      Enum.map(minutes_list, fn minutes ->
        {:ok, dt} =
          DateTime.new(date, Time.new!(div(minutes, 60), rem(minutes, 60), 0), "Etc/UTC")

        dt
      end)
    end)
    |> Enum.filter(fn dt -> DateTime.compare(dt, now) != :gt end)
    |> case do
      [] -> nil
      candidates -> Enum.max_by(candidates, &DateTime.to_unix/1)
    end
  end

  defp post_individual_event_message?(policy, inbox_config) do
    policy.mode != "summarize" or inbox_config.mode != "batched_summary"
  end

  defp apply_event_inbox_state(current_state, occurred_at, policy, inbox_config) do
    cond do
      policy.mode == "summarize" and inbox_config.mode == "batched_summary" ->
        pending_started_at =
          parse_datetime(current_state["pending_summary_started_at"]) || occurred_at

        due? =
          if inbox_config.schedule == "daily" and inbox_config.summary_times != [] do
            daily_summary_due?(pending_started_at, occurred_at, inbox_config.summary_times)
          else
            DateTime.diff(occurred_at, pending_started_at, :second) >=
              inbox_config.summary_window_hours * 3600
          end

        next_state =
          current_state
          |> Map.put("event_inbox_mode", inbox_config.mode)
          |> Map.put("summary_window_hours", inbox_config.summary_window_hours)
          |> Map.put("summary_schedule", inbox_config.schedule)
          |> Map.put("summary_times", inbox_config.summary_times)
          |> Map.put("pending_summary_started_at", DateTime.to_iso8601(pending_started_at))

        {next_state, if(due?, do: pending_started_at, else: nil)}

      true ->
        next_state =
          current_state
          |> Map.put("event_inbox_mode", inbox_config.mode)
          |> Map.put("summary_window_hours", inbox_config.summary_window_hours)
          |> Map.delete("pending_summary_started_at")

        {next_state, nil}
    end
  end

  defp maybe_post_batched_summary(_agent, thread, nil, _occurred_at, _inbox_config),
    do: {:ok, thread, nil}

  defp maybe_post_batched_summary(agent, thread, pending_since, occurred_at, inbox_config) do
    events = pending_summary_events(thread.id, pending_since, occurred_at)

    if events == [] do
      {:ok, thread, nil}
    else
      metadata =
        %{
          "eventThread" => true,
          "eventInboxSummary" => true,
          "eventInboxRole" => "summary",
          "hiddenFromTranscript" => false,
          "eventThreadId" => thread.id,
          "threadKey" => thread.thread_key,
          "source" => thread.source,
          "summaryWindowHours" => inbox_config.summary_window_hours,
          "summaryStartAt" => DateTime.to_iso8601(pending_since),
          "summaryEndAt" => DateTime.to_iso8601(occurred_at),
          "eventIds" => Enum.map(events, & &1.id)
        }

      with {:ok, summary_payload} <-
             post_chat_message(
               agent,
               thread.chat_id,
               build_batch_summary_body(thread, events, pending_since, occurred_at, inbox_config),
               metadata,
               nil
             ) do
        next_state =
          (thread.current_state || %{})
          |> Map.put("last_summary_at", DateTime.to_iso8601(occurred_at))
          |> Map.delete("pending_summary_started_at")

        updated_thread =
          thread
          |> AgentEventThread.changeset(%{
            current_state: next_state,
            root_message_id: thread.root_message_id || summary_payload.message_id
          })
          |> Repo.update!()

        {:ok, updated_thread, summary_payload}
      end
    end
  end

  defp pending_summary_events(thread_id, pending_since, occurred_at) do
    Repo.all(
      from(e in AgentEvent,
        where:
          e.thread_id == ^thread_id and
            e.occurred_at >= ^pending_since and
            e.occurred_at <= ^occurred_at,
        order_by: [asc: e.occurred_at, asc: e.inserted_at]
      )
    )
  end

  defp build_batch_summary_body(thread, events, pending_since, occurred_at, inbox_config) do
    window_label =
      case inbox_config.summary_window_hours do
        24 -> "Daily summary"
        hours -> "#{hours}h summary"
      end

    count = length(events)
    preview_events = Enum.take(events, -@batch_summary_event_line_limit)
    omitted_count = max(count - length(preview_events), 0)

    type_line =
      events
      |> summary_count_line(fn event -> event |> event_type() |> humanize_event_type() end)
      |> case do
        nil -> nil
        counts -> "Types: #{counts}"
      end

    source_line =
      events
      |> summary_count_line(fn event -> Map.get(event, :source) || Map.get(event, "source") end)
      |> case do
        nil -> nil
        counts -> "Sources: #{counts}"
      end

    lines =
      preview_events
      |> Enum.map(fn event ->
        line_body = event |> compact_event_summary_line() |> truncate_line(220)

        "#{summary_timestamp(event.occurred_at)} #{line_body}"
      end)

    omitted_line =
      if omitted_count > 0 do
        [
          "Showing latest #{length(preview_events)} of #{count}; #{omitted_count} earlier event#{if omitted_count == 1, do: "", else: "s"} saved in Inbox."
        ]
      else
        []
      end

    ([
       "#{window_label}: #{count} event#{if count == 1, do: "", else: "s"}",
       "#{thread.title || thread.thread_key}",
       "Window: #{summary_timestamp(pending_since)} to #{summary_timestamp(occurred_at)}",
       type_line,
       source_line
     ] ++ omitted_line ++ ["Events:"] ++ lines)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp summary_timestamp(%DateTime{} = value) do
    Calendar.strftime(value, "%b %d %H:%M")
  rescue
    _ -> DateTime.to_iso8601(value)
  end

  defp summary_count_line(events, value_fun) do
    events
    |> Enum.map(value_fun)
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {label, count} -> {-count, label} end)
    |> Enum.take(4)
    |> case do
      [] ->
        nil

      counts ->
        Enum.map_join(counts, " · ", fn {label, count} -> "#{label} #{count}" end)
    end
  end

  defp truncate_line(nil, _limit), do: nil

  defp truncate_line(text, limit) when is_binary(text) and is_integer(limit) and limit > 3 do
    normalized = String.trim(text)

    if String.length(normalized) <= limit do
      normalized
    else
      String.slice(normalized, 0, limit - 3) <> "..."
    end
  end

  defp execute_runbook(agent, integration, thread, event, runbook, normalized, policy) do
    with {:ok, action_payload} <- runbook_action_payload(normalized, runbook),
         {:ok, execution} <-
           execute_requested_action(agent, thread, action_payload, thread.root_message_id),
         {:ok, _event} <-
           event
           |> AgentEvent.changeset(%{status: "acted"})
           |> Repo.update(),
         {:ok, _thread} <-
           thread
           |> AgentEventThread.changeset(%{
             status: Map.get(execution, :thread_status, thread.status),
             last_decision: "act"
           })
           |> Repo.update() do
      run =
        create_run!(agent, integration, thread, event, runbook, policy, %{
          result: %{
            action: action_payload,
            execution: execution
          }
        })

      {:ok, %{status: "acted", run: run}}
    end
  end

  defp create_approval(agent, integration, thread, event, runbook, normalized, policy) do
    declaration = Map.get(policy, :declaration) || Map.get(normalized, :declaration)

    if match?(%{actions: [_ | _]}, declaration) do
      with {:ok, details} <-
             AgentDecisions.create_declared_decision(
               agent,
               thread,
               event,
               normalized,
               declaration,
               policy
             ) do
        run =
          create_run!(agent, integration, thread, event, runbook, policy, %{
            result: %{
              approvalTaskId: details.approval_task.id,
              source: "declared",
              actionMode: declaration.action_mode
            }
          })

        {:ok, Map.put(details, :run, run)}
      end
    else
      requested_action =
        case runbook_action_payload(normalized, runbook) do
          {:ok, payload} -> payload
          {:error, _} -> fallback_requested_action(normalized)
        end

      task =
        %AgentApprovalTask{}
        |> AgentApprovalTask.changeset(%{
          agent_id: agent.id,
          thread_id: thread.id,
          event_id: event.id,
          runbook_id: runbook && runbook.id,
          chat_id: thread.chat_id,
          requested_action: requested_action,
          rationale: "Approval required for #{normalized.event_type}",
          status: "pending",
          source: "runbook",
          action_mode: "single"
        })
        |> Repo.insert!()

      _ =
        post_system_followup(
          agent,
          thread,
          "Approval needed for #{normalized.title || normalized.event_type}. Open the task to approve or reject.",
          %{
            "approvalTaskId" => task.id,
            "eventThreadId" => thread.id,
            "eventId" => event.id,
            "status" => "pending_approval"
          }
        )

      run =
        create_run!(agent, integration, thread, event, runbook, policy, %{
          result: %{
            approvalTaskId: task.id,
            requestedAction: requested_action
          }
        })

      {:ok, %{status: "approval_required", run: run, approval_task: task}}
    end
  end

  defp runbook_action_payload(normalized, %AgentRunbook{} = runbook) do
    title = normalized.title || humanize_event_type(normalized.event_type)
    config = runbook.action_config || %{}
    action_type = runbook.action_type || "post_message"

    payload =
      %{
        "actionType" => action_type,
        "title" => Map.get(config, "title") || title,
        "message" =>
          Map.get(config, "message") ||
            runbook.instructions ||
            fallback_action_message(normalized)
      }

    payload =
      case Map.get(config, "items") do
        items when is_list(items) -> Map.put(payload, "items", items)
        _ -> payload
      end

    payload =
      case Map.get(config, "status") do
        status when is_binary(status) -> Map.put(payload, "status", status)
        _ -> payload
      end

    {:ok, payload}
  end

  defp runbook_action_payload(_normalized, _runbook), do: {:error, :missing_runbook}

  defp fallback_requested_action(normalized) do
    %{
      "actionType" => "post_message",
      "title" => "Review #{normalized.event_type}",
      "message" => fallback_action_message(normalized)
    }
  end

  defp fallback_action_message(normalized) do
    [
      "Review #{normalized.title || humanize_event_type(normalized.event_type)}.",
      normalize_string(normalized.text)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp execute_requested_action(agent, thread, requested_action, reply_to_id) do
    action_type =
      requested_action["actionType"] || requested_action["action_type"] || "post_message"

    title = normalize_string(requested_action["title"])
    message = normalize_string(requested_action["message"])

    case action_type do
      "post_message" ->
        post_system_followup(agent, thread, join_title_and_body(title, message), %{
          "actionType" => action_type,
          "threadId" => thread.id
        })

      "request_confirmation" ->
        post_system_followup(
          agent,
          thread,
          join_title_and_body(title, message || "Please confirm the next step."),
          %{"actionType" => action_type, "threadId" => thread.id}
        )

      "post_checklist" ->
        checklist =
          requested_action["items"]
          |> List.wrap()
          |> Enum.map(&normalize_string/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map_join("\n", &"- #{&1}")

        post_system_followup(
          agent,
          thread,
          [title, message, checklist] |> Enum.reject(&is_nil/1) |> Enum.join("\n"),
          %{"actionType" => action_type, "threadId" => thread.id}
        )

      "set_thread_status" ->
        {:ok, %{thread_status: normalize_string(requested_action["status"]) || "in_progress"}}

      other ->
        {:error, {:unsupported_action, other, reply_to_id}}
    end
  end

  defp create_run!(agent, integration, thread, event, runbook, policy, extra) do
    cost_usd =
      policy.estimated_cost_cents
      |> D.new()
      |> D.div(D.new(100))

    %AgentRun{}
    |> AgentRun.changeset(%{
      agent_id: agent.id,
      integration_id: integration && integration.id,
      thread_id: thread.id,
      event_id: event.id,
      runbook_id: runbook && runbook.id,
      trigger: "event_ingestion",
      mode: policy.mode,
      model: if(policy.mode == "summarize", do: "rule+template", else: "runbook"),
      prompt_version: "event_threads_v1",
      decision: policy.reason,
      audit_summary: "#{policy.mode}: #{policy.reason}",
      result: Map.get(extra, :result, %{}),
      tool_calls: %{"items" => []},
      status: "completed",
      cost_usd: cost_usd
    })
    |> Repo.insert!()
  end

  defp post_event_message(agent, thread, event, normalized, policy, silent) do
    title = normalized.title || humanize_event_type(normalized.event_type)
    detail = event_display_detail(normalized) || summarize_payload_line(normalized.payload)
    body = event_message_body(title, detail)

    metadata = %{
      "eventThread" => true,
      "eventInboxRole" => if(silent, do: "raw_event", else: "event"),
      "hiddenFromTranscript" => silent,
      "eventThreadId" => thread.id,
      "eventId" => event.id,
      "threadKey" => thread.thread_key,
      "eventType" => normalized.event_type,
      "source" => normalized.source,
      "priority" => policy.priority,
      "decision" => policy.mode,
      "payload" => normalized.payload,
      "attachments" => normalize_attachments_payload(normalized.attachments)
    }

    post_event_body_and_attachments(
      agent,
      thread.chat_id,
      body,
      caption_body(title, detail),
      metadata,
      normalize_attachments_payload(normalized.attachments),
      silent
    )
  end

  defp caption_body(title, nil), do: title
  defp caption_body(title, detail), do: "#{title}\n\n#{detail}"

  defp post_event_body_and_attachments(
         agent,
         chat_id,
         _body,
         caption,
         metadata,
         [first | rest],
         false
       ) do
    with {:ok, primary_message} <-
           post_attachment_message(
             agent,
             chat_id,
             merged_attachment_caption(caption, first),
             metadata,
             first,
             nil
           ),
         {:ok, _attachment_messages} <-
           post_event_attachments(agent, chat_id, rest, metadata, nil, false) do
      {:ok, primary_message}
    end
  end

  defp post_event_body_and_attachments(
         agent,
         chat_id,
         body,
         _caption,
         metadata,
         attachments,
         silent
       ) do
    with {:ok, primary_message} <-
           maybe_post_event_summary(agent, chat_id, body, metadata, nil, silent),
         {:ok, _attachment_messages} <-
           post_event_attachments(agent, chat_id, attachments, metadata, nil, silent) do
      {:ok, primary_message}
    end
  end

  @doc false
  def merged_attachment_caption(body, attachment) do
    case {normalize_string(body), attachment_own_caption(attachment)} do
      {nil, nil} ->
        nil

      {text, nil} ->
        text

      {nil, caption} ->
        caption

      {text, caption} ->
        if String.contains?(text, caption), do: text, else: "#{text}\n\n#{caption}"
    end
  end

  defp post_system_followup(agent, thread, body, metadata) do
    post_chat_message(
      agent,
      thread.chat_id,
      body,
      Map.put(metadata, "eventThreadId", thread.id),
      thread.root_message_id
    )
  end

  defp post_chat_message(agent, chat_id, body, metadata, reply_to_id) do
    post_chat_message(agent, chat_id, body, metadata, reply_to_id, [])
  end

  defp post_chat_message(agent, chat_id, body, metadata, reply_to_id, opts) do
    message_id = Ecto.UUID.generate()
    timestamp = System.system_time(:millisecond)
    message_type = Keyword.get(opts, :type, "text")
    media_url = Keyword.get(opts, :media_url)
    silent = Keyword.get(opts, :silent, false)

    metadata =
      metadata
      |> maybe_put("fileName", normalize_string(metadata["fileName"] || metadata[:fileName]))
      |> maybe_put("fileSize", normalize_integer(metadata["fileSize"] || metadata[:fileSize]))
      |> maybe_put("duration", normalize_number(metadata["duration"] || metadata[:duration]))
      |> maybe_put("mimeType", normalize_string(metadata["mimeType"] || metadata[:mimeType]))
      |> maybe_put("caption", normalize_string(metadata["caption"] || metadata[:caption]))
      |> maybe_put(
        "isVideoNote",
        normalize_boolean(metadata["isVideoNote"] || metadata[:isVideoNote])
      )

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
        type: message_type,
        media_url: media_url,
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
          ),
        reply_to_id: reply_to_id,
        timestamp: timestamp
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Chat.add_message(attrs, acting_user_id: agent.agent_user_id) do
      {:ok, _message} ->
        payload =
          %{
            "id" => message_id,
            "fromId" => agent.agent_user_id,
            "chatId" => chat_id,
            "encryptedContent" => "",
            "plainContent" => body,
            "plaintext" => body,
            "type" => message_type,
            "mediaUrl" => media_url,
            "fileName" => metadata["fileName"],
            "fileSize" => metadata["fileSize"],
            "duration" => metadata["duration"],
            "caption" => metadata["caption"] || normalize_string(body),
            "isVideoNote" => metadata["isVideoNote"],
            "timestamp" => timestamp,
            "status" => "sent",
            "isAgentMessage" => true,
            "agentName" => agent.display_name,
            "agentId" => agent.id,
            "agentUserId" => agent.agent_user_id,
            "agentUsername" => agent_username,
            "agentHandle" => if(agent_username, do: "@#{agent_username}", else: nil),
            "metadata" => attrs.metadata,
            "replyToId" => reply_to_id
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message", payload)

        mirrored_message = Chat.mirrored_message_payload(payload)

        Chat.get_all_participant_settings(chat_id)
        |> Enum.each(fn participant ->
          if participant.user_id != agent.agent_user_id do
            if participant.deleted, do: Chat.restore_if_deleted(chat_id, participant.user_id)

            if not silent do
              VibeWeb.Endpoint.broadcast!("user:#{participant.user_id}", "new_message", %{
                chat_id: chat_id,
                from_id: agent.agent_user_id,
                message_id: message_id,
                timestamp: timestamp,
                muted: participant.muted || false,
                message: mirrored_message
              })
            end

            if not participant.muted and not silent do
              _ =
                Notifications.send_message_push(participant.user_id, %{
                  "chat_id" => chat_id,
                  "message_id" => message_id,
                  "from_id" => agent.agent_user_id,
                  "type" => message_type,
                  "body" => normalize_string(body),
                  "media_url" => media_url
                })
            end
          end
        end)

        {:ok, %{message_id: message_id, timestamp: timestamp}}

      error ->
        error
    end
  end

  defp maybe_post_event_summary(agent, chat_id, body, metadata, reply_to_id, silent) do
    if normalize_string(body) do
      post_chat_message(agent, chat_id, body, metadata, reply_to_id, silent: silent)
    else
      {:ok, nil}
    end
  end

  defp post_event_attachments(_agent, _chat_id, [], _metadata, _reply_to_id, _silent),
    do: {:ok, []}

  defp post_event_attachments(agent, chat_id, attachments, metadata, reply_to_id, _silent) do
    attachments
    |> Enum.reduce_while({:ok, []}, fn attachment, {:ok, acc} ->
      case post_attachment_message(
             agent,
             chat_id,
             attachment_own_caption(attachment),
             metadata,
             attachment,
             reply_to_id
           ) do
        {:ok, message_payload} ->
          {:cont, {:ok, acc ++ [message_payload]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp post_attachment_message(agent, chat_id, caption, metadata, attachment, reply_to_id) do
    attachment_metadata =
      metadata
      |> Map.put("eventInboxRole", "attachment")
      |> Map.put("hiddenFromTranscript", false)
      |> Map.put("attachment", attachment)
      |> maybe_put("fileName", attachment_file_name(attachment))
      |> maybe_put(
        "fileSize",
        normalize_integer(attachment["fileSize"] || attachment[:fileSize])
      )
      |> maybe_put(
        "duration",
        normalize_number(attachment["duration"] || attachment[:duration])
      )
      |> maybe_put("mimeType", attachment_mime_type(attachment))
      |> maybe_put(
        "isVideoNote",
        normalize_boolean(attachment["isVideoNote"] || attachment[:isVideoNote])
      )
      |> maybe_put("caption", caption)

    post_chat_message(
      agent,
      chat_id,
      caption || "",
      attachment_metadata,
      reply_to_id,
      type: attachment_message_type(attachment),
      media_url: attachment["url"],
      silent: false
    )
  end

  defp attachment_own_caption(attachment) do
    normalize_string(
      attachment["caption"] || attachment[:caption] || attachment["title"] ||
        attachment[:title] || attachment["text"] || attachment[:text]
    )
  end

  defp touch_integration!(%AgentIntegration{} = integration) do
    integration
    |> AgentIntegration.changeset(%{last_event_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp matching_runbook(agent, integration, event_type) do
    integration_id = integration && integration.id

    query =
      from(r in AgentRunbook,
        where: r.agent_id == ^agent.id and r.enabled == true,
        order_by: [desc: r.integration_id, asc: r.inserted_at]
      )

    query =
      if is_binary(integration_id) do
        from(r in query, where: is_nil(r.integration_id) or r.integration_id == ^integration_id)
      else
        from(r in query, where: is_nil(r.integration_id))
      end

    Repo.all(query)
    |> Enum.find(fn runbook ->
      types = List.wrap(runbook.event_types_enabled)
      types == [] or event_type in types
    end)
  end

  defp verify_integration_secret(%AgentIntegration{} = integration, secret)
       when is_binary(secret) do
    secure_compare(hash_secret(secret), integration.secret_hash || "")
  end

  defp verify_integration_secret(_integration, _secret), do: false

  defp hash_secret(secret) do
    :crypto.hash(:sha256, secret)
    |> Base.encode16(case: :lower)
  end

  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp normalize_payload(value) when is_map(value) do
    value
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_payload(_), do: %{}

  defp normalize_attachments(value) when is_list(value) do
    items =
      value
      |> Enum.take(@max_attachment_count)
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn item ->
        %{
          "type" => normalize_string(item["type"] || item[:type]),
          "url" =>
            normalize_string(item["url"] || item[:url] || item["mediaUrl"] || item[:mediaUrl]),
          "name" =>
            normalize_string(
              item["name"] || item[:name] || item["fileName"] || item[:fileName] ||
                item["filename"] || item[:filename]
            ),
          "mimeType" =>
            normalize_string(
              item["mimeType"] || item[:mimeType] || item["mime_type"] || item[:mime_type] ||
                item["mime"] || item[:mime]
            ),
          "caption" =>
            normalize_rich_text(
              item["caption"] || item[:caption] || item["title"] || item[:title]
            ),
          "text" => normalize_rich_text(item["text"] || item[:text]),
          "duration" => normalize_number(item["duration"] || item[:duration]),
          "fileSize" =>
            normalize_integer(
              item["fileSize"] || item[:fileSize] || item["file_size"] || item[:file_size]
            ),
          "isVideoNote" =>
            normalize_boolean(
              item["isVideoNote"] || item[:isVideoNote] || item["is_video_note"] ||
                item[:is_video_note]
            )
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()
      end)
      |> Enum.filter(&(is_binary(&1["url"]) and valid_attachment_url?(&1["url"])))

    %{"items" => items}
  end

  defp normalize_attachments(_), do: %{"items" => []}

  defp normalize_attachments_payload(%{"items" => items}) when is_list(items), do: items
  defp normalize_attachments_payload(_), do: []

  defp attachment_items?(%{"items" => items}) when is_list(items), do: items != []
  defp attachment_items?(_), do: false

  defp normalize_rich_text(value) do
    value
    |> normalize_string()
    |> case do
      nil ->
        nil

      text ->
        text
        |> String.replace(~r/<\s*br\s*\/?\s*>/iu, "\n")
        |> String.replace(~r/<\s*\/\s*(p|div|li|ul|ol|tr|table|h[1-6]|blockquote)\s*>/iu, "\n")
        |> String.replace(~r/<\s*li\b[^>]*>/iu, "- ")
        |> String.replace(~r/<[^>]+>/u, "")
        |> decode_html_entities()
        |> String.replace("\u{00A0}", " ")
        |> String.replace("\r\n", "\n")
        |> String.replace("\r", "\n")
        |> String.replace(~r/[ \t]+\n/u, "\n")
        |> String.replace(~r/\n{3,}/u, "\n\n")
        |> String.trim()
        |> String.slice(0, @max_rich_text_chars)
        |> normalize_string()
    end
  end

  defp valid_attachment_url?(url) when is_binary(url) do
    byte_size(url) <= @max_attachment_url_chars and
      case URI.parse(url) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          true

        _ ->
          false
      end
  end

  defp valid_attachment_url?(_), do: false

  defp validate_event_params_size(params) do
    if json_size_within?(params, @max_event_params_bytes),
      do: :ok,
      else: {:error, :event_payload_too_large}
  end

  defp json_size_within?(value, max_bytes) do
    case Jason.encode_to_iodata(value) do
      {:ok, iodata} -> IO.iodata_length(iodata) <= max_bytes
      {:error, _} -> false
    end
  end

  defp decode_html_entities(text) when is_binary(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&#39;", "'")
    |> then(fn current ->
      Regex.replace(~r/&#x([0-9a-fA-F]+);/u, current, fn _, hex -> decode_codepoint(hex, 16) end)
    end)
    |> then(fn current ->
      Regex.replace(~r/&#([0-9]+);/u, current, fn _, digits -> decode_codepoint(digits, 10) end)
    end)
  end

  defp decode_codepoint(raw, base) do
    case Integer.parse(raw, base) do
      {codepoint, ""} when codepoint >= 0 and codepoint <= 0x10FFFF ->
        try do
          <<codepoint::utf8>>
        rescue
          _ -> ""
        end

      _ ->
        ""
    end
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" or trimmed in ["nil", "null", "undefined"] do
      nil
    else
      trimmed
    end
  end

  defp normalize_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_string()

  defp normalize_string(_), do: nil

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_float(value) do
    if finite_number?(value), do: round(value), else: nil
  end

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp normalize_integer(_), do: nil

  defp normalize_number(value) when is_integer(value), do: value * 1.0

  defp normalize_number(value) when is_float(value) do
    if finite_number?(value), do: value, else: nil
  end

  defp normalize_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp normalize_number(_), do: nil

  defp normalize_boolean(value) when value in [true, false], do: value
  defp normalize_boolean(value) when value in ["true", "1", 1], do: true
  defp normalize_boolean(value) when value in ["false", "0", 0], do: false
  defp normalize_boolean(_), do: nil

  defp finite_number?(value) when is_float(value), do: value == value

  defp attachment_message_type(attachment) when is_map(attachment) do
    explicit =
      normalize_string(
        attachment["messageType"] || attachment[:messageType] || attachment["message_type"] ||
          attachment[:message_type] || attachment["type"] || attachment[:type]
      )
      |> normalize_attachment_type()

    explicit || infer_attachment_message_type(attachment)
  end

  defp attachment_message_type(_attachment), do: "file"

  defp normalize_attachment_type(type) do
    case normalize_string(type) do
      "image" -> "image"
      "gif" -> "gif"
      "video" -> "video"
      "video_note" -> "video"
      "voice" -> "voice"
      "audio" -> "music"
      "music" -> "music"
      "mp3" -> "music"
      "file" -> "file"
      "document" -> "file"
      _ -> nil
    end
  end

  defp infer_attachment_message_type(attachment) do
    mime_type = attachment_mime_type(attachment) || ""
    url = normalize_string(attachment["url"] || attachment[:url]) || ""
    lowered_mime = String.downcase(mime_type)
    lowered_url = String.downcase(url)

    cond do
      String.starts_with?(lowered_mime, "image/gif") or
          String.match?(lowered_url, ~r/\.gif(\?|$)/) ->
        "gif"

      String.starts_with?(lowered_mime, "image/") or
          String.match?(lowered_url, ~r/\.(png|jpe?g|webp|heic|bmp)(\?|$)/) ->
        "image"

      String.starts_with?(lowered_mime, "video/") or
          String.match?(lowered_url, ~r/\.(mp4|mov|m4v|webm|mkv)(\?|$)/) ->
        "video"

      String.starts_with?(lowered_mime, "audio/") or
          String.match?(lowered_url, ~r/\.(mp3|m4a|aac|wav|ogg|oga|flac)(\?|$)/) ->
        "music"

      true ->
        "file"
    end
  end

  @doc false
  def attachment_file_name(attachment) do
    normalize_string(attachment["name"] || attachment[:name]) ||
      file_name_from_url(normalize_string(attachment["url"] || attachment[:url]))
  end

  defp file_name_from_url(nil), do: nil

  defp file_name_from_url(url) do
    case URI.parse(url).path do
      nil ->
        nil

      path ->
        case path |> Path.basename() |> URI.decode() |> normalize_string() do
          nil -> nil
          "/" -> nil
          name -> if named_file?(name), do: name
        end
    end
  end

  defp named_file?(name) do
    case Path.extname(name) do
      "" -> false
      ext -> String.match?(ext, ~r/^\.[A-Za-z0-9]{1,8}$/)
    end
  end

  @doc false
  def attachment_mime_type(attachment) do
    normalize_string(attachment["mimeType"] || attachment[:mimeType]) ||
      mime_type_from_extension(attachment_file_name(attachment))
  end

  defp mime_type_from_extension(nil), do: nil

  defp mime_type_from_extension(name) do
    case name |> Path.extname() |> String.downcase() do
      ".pdf" -> "application/pdf"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      ".heic" -> "image/heic"
      ".gif" -> "image/gif"
      ".mp4" -> "video/mp4"
      ".mov" -> "video/quicktime"
      ".mp3" -> "audio/mpeg"
      ".m4a" -> "audio/mp4"
      ".ogg" -> "audio/ogg"
      ".wav" -> "audio/wav"
      ".csv" -> "text/csv"
      ".txt" -> "text/plain"
      ".zip" -> "application/zip"
      ".doc" -> "application/msword"
      ".docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      ".xls" -> "application/vnd.ms-excel"
      ".xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      _ -> nil
    end
  end

  defp build_fingerprint(source, title, text, occurred_at, payload) do
    [
      source,
      title,
      text,
      DateTime.to_iso8601(occurred_at),
      Jason.encode!(payload)
    ]
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp humanize_event_type(event_type) do
    event_type
    |> to_string()
    |> String.replace(".", " ")
    |> String.replace("_", " ")
    |> String.trim()
    |> String.capitalize()
  end

  defp event_message_body(title, nil), do: "# #{title}"
  defp event_message_body(title, detail), do: "# #{title}\n\n#{detail}"

  defp compact_event_summary_line(eventish) do
    title =
      eventish
      |> event_title()
      |> normalize_string()

    detail =
      eventish
      |> event_display_detail()
      |> normalize_string()

    [title, detail]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" — ")
    |> normalize_string()
  end

  defp event_display_detail(eventish) do
    payload = event_payload(eventish)

    display_summary =
      payload
      |> payload_group("display")
      |> payload_value(["summary", "text", "description"])
      |> normalize_string()

    analytics_summary =
      if analytics_event?(eventish, payload) do
        analytics_event_summary(payload)
      end

    display_summary || analytics_summary || normalize_string(event_text(eventish))
  end

  defp analytics_event?(eventish, payload) do
    event_type = event_type(eventish) || ""

    String.starts_with?(event_type, "analytics.") or
      Map.has_key?(payload, "traffic") or Map.has_key?(payload, "commerce") or
      Map.has_key?(payload, "funnel")
  end

  defp analytics_event_summary(payload) do
    traffic = payload_group(payload, "traffic")
    commerce = payload_group(payload, "commerce")
    funnel = payload_group(payload, "funnel")

    metric_line =
      [
        metric_phrase(payload_value(traffic, ["sessions"]), "session", "sessions"),
        metric_phrase(
          payload_value(traffic, ["pageViews", "page_views"]),
          "page view",
          "page views"
        ),
        metric_phrase(
          payload_value(commerce, ["addToCartEvents", "add_to_cart_events"]),
          "add-to-cart event",
          "add-to-cart events"
        ),
        metric_phrase(
          payload_value(commerce, ["checkoutSessions", "checkout_sessions"]),
          "checkout session",
          "checkout sessions"
        ),
        metric_phrase(
          payload_value(commerce, ["paidOrders", "paid_orders"]),
          "paid order",
          "paid orders"
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")
      |> normalize_string()

    highlights =
      [
        top_item_phrase("Top country", payload_value(traffic, ["topCountries", "top_countries"])),
        top_item_phrase("Top source", payload_value(traffic, ["topSources", "top_sources"])),
        top_item_phrase(
          "Most-added product",
          payload_value(commerce, ["topAddedProducts", "top_added_products"])
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")
      |> normalize_string()

    funnel_line =
      [
        rate_phrase(
          "cart rate",
          payload_value(funnel, ["sessionToCartRate", "session_to_cart_rate"])
        ),
        rate_phrase(
          "purchase rate",
          payload_value(funnel, ["sessionToPurchaseRate", "session_to_purchase_rate"])
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")
      |> normalize_string()

    [metric_line, highlights, funnel_line]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> normalize_string()
  end

  defp metric_phrase(nil, _singular, _plural), do: nil

  defp metric_phrase(value, singular, plural) do
    case normalize_number(value) do
      nil ->
        nil

      number ->
        label = if number == 1.0, do: singular, else: plural
        "#{format_number(number)} #{label}"
    end
  end

  defp rate_phrase(_label, nil), do: nil

  defp rate_phrase(label, value) do
    case normalize_number(value) do
      nil -> nil
      number -> "#{label}: #{format_number(number)}%"
    end
  end

  defp top_item_phrase(_label, nil), do: nil
  defp top_item_phrase(_label, []), do: nil

  defp top_item_phrase(label, [first | _]), do: top_item_phrase(label, first)

  defp top_item_phrase(label, %{} = item) do
    name = item |> payload_value(["name", "label", "value"]) |> normalize_string()
    count = payload_value(item, ["count", "total"])

    cond do
      is_nil(name) -> nil
      is_nil(count) -> "#{label}: #{name}"
      true -> "#{label}: #{name} (#{format_payload_value(count)})"
    end
  end

  defp top_item_phrase(label, value) do
    case normalize_string(value) do
      nil -> nil
      text -> "#{label}: #{text}"
    end
  end

  defp payload_group(payload, key) when is_map(payload) do
    payload
    |> payload_value([key, Macro.underscore(key)])
    |> decode_payload_value()
    |> case do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp payload_group(_payload, _key), do: %{}

  defp payload_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      key = to_string(key)
      Map.get(map, key) || Map.get(map, Macro.underscore(key))
    end)
    |> decode_payload_value()
  end

  defp payload_value(_map, _keys), do: nil

  defp decode_payload_value(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp decode_payload_value(value), do: value

  defp event_title(eventish) do
    Map.get(eventish, :title) || Map.get(eventish, "title") ||
      humanize_event_type(event_type(eventish))
  end

  defp event_text(eventish), do: Map.get(eventish, :text) || Map.get(eventish, "text")

  defp event_type(eventish) do
    Map.get(eventish, :event_type) || Map.get(eventish, "eventType") ||
      Map.get(eventish, "event_type")
  end

  defp event_payload(eventish) do
    case Map.get(eventish, :payload) || Map.get(eventish, "payload") || Map.get(eventish, "data") do
      payload when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp format_number(value) when is_integer(value), do: Integer.to_string(value)

  defp format_number(value) when is_float(value) do
    rounded = Float.round(value, 2)

    if rounded == Float.round(rounded, 0) do
      rounded |> round() |> Integer.to_string()
    else
      rounded
      |> :erlang.float_to_binary(decimals: 2)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")
    end
  end

  defp summarize_payload_line(payload) when map_size(payload) == 0, do: nil

  defp summarize_payload_line(payload) do
    payload
    |> Enum.take(4)
    |> Enum.map_join(" · ", fn {key, value} ->
      "#{humanize_payload_key(key)}: #{format_payload_value(value)}"
    end)
  end

  defp humanize_payload_key(key) do
    key
    |> to_string()
    |> String.replace(["_", "."], " ")
    |> String.trim()
  end

  defp format_payload_value(value) when is_list(value) do
    cond do
      value == [] ->
        "none"

      Enum.all?(value, &scalar_payload_value?/1) ->
        Enum.map_join(value, ", ", &format_payload_value/1)

      true ->
        count = length(value)
        "#{count} item#{if count == 1, do: "", else: "s"}"
    end
  end

  defp format_payload_value(value) when is_map(value) do
    count = map_size(value)
    "#{count} field#{if count == 1, do: "", else: "s"}"
  end

  defp format_payload_value(value) when is_binary(value), do: value
  defp format_payload_value(value) when is_boolean(value), do: to_string(value)
  defp format_payload_value(value) when is_number(value), do: to_string(value)
  defp format_payload_value(nil), do: "none"
  defp format_payload_value(value), do: inspect(value)

  defp scalar_payload_value?(value) do
    is_binary(value) or is_number(value) or is_boolean(value)
  end

  defp join_title_and_body(nil, nil), do: ""
  defp join_title_and_body(title, nil), do: title
  defp join_title_and_body(nil, body), do: body
  defp join_title_and_body(title, body), do: "#{title}\n#{body}"

  defp noise_duplicate?(normalized, %AgentEvent{} = last_event) do
    same_shape? =
      last_event.event_type == normalized.event_type and
        normalize_string(last_event.title) == normalized.title and
        normalize_string(last_event.text) == normalized.text

    occurred_delta =
      case last_event.occurred_at do
        %DateTime{} = dt -> abs(DateTime.diff(normalized.occurred_at, dt, :second))
        _ -> 999_999
      end

    same_shape? and occurred_delta <= 300
  end

  defp noise_duplicate?(_normalized, _last_event), do: false

  defp initial_event_status("act"), do: "acted"
  defp initial_event_status("approval_required"), do: "approval_required"
  defp initial_event_status("summarize"), do: "summarized"
  defp initial_event_status(_), do: "logged"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
