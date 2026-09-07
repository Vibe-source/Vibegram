defmodule VibeWeb.ChatChannel do
  use VibeWeb, :channel
  alias Vibe.Agent
  alias Vibe.AgentBridge
  alias Vibe.AgentGateway
  alias Vibe.Agents
  alias Vibe.Chat
  alias Vibe.Chat.AgentMessageCrypto
  alias Vibe.Chat.JoinCache
  alias Vibe.Notifications
  alias Vibe.AI.AgentDecisions
  alias Vibe.AI.GroupAgent
  alias Vibe.AI.LocalAgentWorker
  alias Vibe.AI.StandaloneAgent
  alias Vibe.AI.Transcribe
  require Logger

  # Sealed agent image blobs (arte1).
  @inline_attachment_keys ~w(agentBridgeAttachmentsEnc agent_bridge_attachments_enc attachmentsEnc)
  @impl true
  def join("chat:" <> chat_id, _payload, socket) do
    user_id = socket.assigns.user_id
    case Chat.join_context(chat_id, user_id) do
      nil ->
        {:error, %{reason: "unauthorized"}}

      {role, type} ->
        room_type = type || "dm"
        socket = assign(socket, :room_type, room_type)
        socket = assign(socket, :user_role, role)

        standalone_agent =
          case room_type do
            "dm" ->
              JoinCache.fetch_dm_agent(chat_id, user_id, fn ->
                Chat.dm_standalone_agent(chat_id, user_id)
              end)

            _ ->
              nil
          end

        socket = assign(socket, :standalone_agent, standalone_agent)

        socket =
          assign(
            socket,
            :standalone_agent_chat_enabled,
            is_nil(standalone_agent) or Agents.incoming_chat_enabled?(standalone_agent)
          )

        send(self(), {:replay_pending_ask, chat_id})
        {:ok, socket}
    end
  end

  @impl true
  def handle_info({:replay_pending_ask, chat_id}, socket) do
    case AgentBridge.pending_ask(chat_id) do
      payload when is_map(payload) ->
        Logger.info(
          "[AgentBridge][ask] replay-on-join chat=#{chat_id} " <>
            "requestId=#{inspect(payload["requestId"])} → push agent-bridge-ask"
        )

        push(socket, "agent-bridge-ask", payload)

      _ ->
        :noop
    end

    {:noreply, socket}
  end

  # Catch-all:
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_in("message", payload, socket) do
    ack_started_at = System.monotonic_time(:microsecond)
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    VibeWeb.ChannelThrottle.check!(user_id, :message)

    can_send =
      case socket.assigns.room_type do
        "channel" -> socket.assigns.user_role in ["owner", "admin"]
        _ -> true
      end

    if not can_send do
      {:reply, {:error, %{reason: "not_allowed", message: "You cannot send messages here"}},
       socket}
    else
      standalone_agent = socket.assigns[:standalone_agent]

      if standalone_agent && !socket.assigns[:standalone_agent_chat_enabled] do
        {:reply,
         {:error,
          %{reason: "agent_chat_disabled", message: "Incoming chat is disabled for this agent"}},
         socket}
      else
        data = deobfuscate(payload)
        broadcast_payload = strip_inline_agent_attachments(enforce_sender_identity(data, user_id))
        message_metadata = message_metadata_for_persistence(data, standalone_agent)

        if Chat.content_copy_restricted?(message_metadata) do
          {:reply,
           {:error,
            %{
              reason: "content_saving_restricted",
              message: "Forwarding is disabled for this channel"
            }}, socket}
        else
          resolved_media_url =
            durable_media_url(
              data["mediaUrl"] || data["media_url"] || message_metadata["mediaUrl"]
            )

          message_attrs = %{
            chat_id: chat_id,
            from_id: user_id,
            id: data["id"],
            encrypted_content: data["encryptedContent"],
            type: data["type"] || "text",
            timestamp: data["timestamp"] || :os.system_time(:millisecond),
            reply_to_id: data["replyToId"],
            media_url: resolved_media_url,
            metadata: message_metadata
          }

          Logger.info(
            "[MediaDrop] persist chat=#{chat_id} mid=#{data["id"]} type=#{message_attrs.type} media=#{if(is_binary(resolved_media_url), do: "REMOTE", else: "nil")} meta_thumbs=#{inspect(is_list(message_metadata["attachmentThumbnailsB64"]))} meta_thumb?=#{is_binary(message_metadata["thumbnailBase64"])} stripped_blobs=true"
          )

          broadcast!(socket, "message", broadcast_payload)

          mirrored_message = Vibe.Chat.mirrored_message_payload(broadcast_payload)

          VibeWeb.Endpoint.broadcast!("user:#{user_id}", "new_message", %{
            chat_id: chat_id,
            from_id: user_id,
            message_id: data["id"],
            timestamp: data["timestamp"],
            self_echo: true,
            message: mirrored_message
          })

          Task.start(fn -> maybe_dispatch_agent(chat_id, data, user_id) end)

          Task.start(fn ->
            case Chat.add_message(message_attrs, acting_user_id: user_id) do
              {:ok, _msg} ->
                participants = Chat.get_all_participant_settings(chat_id)

                Logger.info(
                  "[ChatChannel] message persisted chat_id=#{chat_id} sender=#{user_id} participants=#{length(participants)} message_id=#{data["id"]}"
                )

                Enum.each(participants, fn p ->
                  if p.user_id != user_id do
                    if p.deleted, do: Chat.restore_if_deleted(chat_id, p.user_id)

                    VibeWeb.Endpoint.broadcast!("user:#{p.user_id}", "new_message", %{
                      chat_id: chat_id,
                      from_id: user_id,
                      message_id: data["id"],
                      timestamp: data["timestamp"],
                      muted: p.muted || false,
                      message: mirrored_message
                    })

                    if p.muted do
                      Logger.info(
                        "[ChatChannel] push skipped (muted chat) recipient=#{p.user_id} chat_id=#{chat_id} message_id=#{data["id"]}"
                      )
                    else
                      push_body =
                        case data["pushPreview"] || data["push_preview"] || data["textPreview"] ||
                               data["text_preview"] do
                          value when is_binary(value) and value != "" -> value
                          _ -> nil
                        end

                      push_kind = data["pushKind"] || data["push_kind"]

                      _ =
                        Notifications.send_message_push(p.user_id, %{
                          "chat_id" => chat_id,
                          "message_id" => data["id"],
                          "from_id" => user_id,
                          "type" => data["type"],
                          "push_kind" => push_kind,
                          "body" => push_body,
                          "media_url" => data["mediaUrl"] || data["media_url"]
                        })
                    end
                  end
                end)

              {:error, changeset} ->
                Logger.error("Message persistence failed: #{inspect(changeset)}")
            end
          end)

          ack_held_us = System.monotonic_time(:microsecond) - ack_started_at

          Logger.info(
            "[ChatChannel] ⏱️ ack held #{ack_held_us}µs chat_id=#{chat_id} message_id=#{data["id"]}"
          )

          {:reply, :ok, socket}
        end
      end
    end
  catch
    {:throttled, reply} -> {:reply, {:error, reply}, socket}
  end

  @impl true
  def handle_in("provider-event", payload, socket) when is_map(payload) do
    "chat:" <> chat_id = socket.topic

    with %{} = agent <- socket.assigns[:standalone_agent],
         true <- socket.assigns[:standalone_agent_chat_enabled],
         {:ok, event_type, event_payload} <- provider_event_payload(payload, chat_id, agent.id),
         {:ok, _delivery} <- deliver_provider_event(agent, event_type, event_payload) do
      {:reply, :ok, socket}
    else
      nil -> {:reply, {:error, %{reason: "agent_not_available"}}, socket}
      false -> {:reply, {:error, %{reason: "agent_chat_disabled"}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("agent-bridge-control", payload, socket) when is_map(payload) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    action = normalize_control_action(payload["action"] || payload["type"])
    provider = normalize_bridge_provider(payload["provider"] || payload["agentBridgeProvider"])

    task_id =
      normalize_bridge_string(payload["taskId"] || payload["agentTaskId"] || payload["messageId"])

    team_run_id =
      normalize_bridge_string(payload["teamRunId"] || payload["team_run_id"])

    cond do
      is_nil(action) ->
        {:reply, {:error, %{reason: "invalid_action"}}, socket}

      action in ["cancel", "stop"] and is_binary(team_run_id) ->
        targets =
          LocalAgentWorker.cancel_bridge_team_run(chat_id, team_run_id, user_id)

        results =
          Enum.map(targets, fn target ->
            control_payload =
              %{
                "action" => action,
                "provider" => target.provider,
                "chatId" => chat_id,
                "requesterUserId" => user_id,
                "teamRunId" => team_run_id
              }
              |> put_optional_string("taskId", target.task_id)
              |> put_optional_string(
                "computerId",
                normalize_bridge_string(payload["computerId"] || payload["agentBridgeComputerId"])
              )

            AgentBridge.dispatch_control(user_id, control_payload)
          end)

        _ =
          if is_binary(provider) do
            AgentBridge.dispatch_control(user_id, %{
              "action" => action,
              "provider" => provider,
              "chatId" => chat_id,
              "requesterUserId" => user_id,
              "teamRunId" => team_run_id,
              "taskId" => task_id
            })
          end

        if Enum.any?(results, &(&1 == :ok)) or is_binary(provider) do
          {:reply, :ok, socket}
        else
          {:reply, {:error, %{reason: "cancel_failed"}}, socket}
        end

      is_nil(provider) ->
        {:reply, {:error, %{reason: "invalid_provider"}}, socket}

      true ->
        control_payload =
          %{
            "action" => action,
            "provider" => provider,
            "chatId" => chat_id,
            "requesterUserId" => user_id
          }
          |> put_optional_string("taskId", task_id)
          |> put_optional_string("teamRunId", team_run_id)
          |> put_optional_string(
            "computerId",
            normalize_bridge_string(payload["computerId"] || payload["agentBridgeComputerId"])
          )

        case AgentBridge.dispatch_control(user_id, control_payload) do
          :ok -> {:reply, :ok, socket}
          {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
        end
    end
  end

  @impl true
  def handle_in("agent-bridge-history", payload, socket) when is_map(payload) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    provider = normalize_bridge_provider(payload["provider"] || payload["agentBridgeProvider"])

    if is_nil(provider) do
      {:reply, {:error, %{reason: "invalid_provider"}}, socket}
    else
      request_payload =
        %{
          "requestId" => normalize_bridge_string(payload["requestId"]) || Ecto.UUID.generate(),
          "provider" => provider,
          "chatId" => chat_id,
          "requesterUserId" => user_id,
          "mode" => normalize_bridge_string(payload["mode"]) || "list"
        }
        |> put_optional_string("sessionId", normalize_bridge_string(payload["sessionId"]))
        |> put_optional_string(
          "before",
          normalize_bridge_string(payload["before"] || payload["beforeCursor"])
        )
        |> put_optional_positive_integer("limit", payload["limit"])
        |> put_optional_string(
          "computerId",
          normalize_bridge_string(payload["computerId"] || payload["agentBridgeComputerId"])
        )

      case AgentBridge.dispatch_history(user_id, request_payload) do
        :ok -> {:reply, {:ok, %{"requestId" => request_payload["requestId"]}}, socket}
        {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
      end
    end
  end

  def handle_in("agent-bridge-file", payload, socket) when is_map(payload) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    provider = normalize_bridge_provider(payload["provider"] || payload["agentBridgeProvider"])
    file_path = normalize_bridge_string(payload["path"] || payload["file"])

    cond do
      is_nil(provider) ->
        {:reply, {:error, %{reason: "invalid_provider"}}, socket}

      is_nil(file_path) ->
        {:reply, {:error, %{reason: "invalid_path"}}, socket}

      true ->
        request_payload =
          %{
            "requestId" => normalize_bridge_string(payload["requestId"]) || Ecto.UUID.generate(),
            "provider" => provider,
            "chatId" => chat_id,
            "requesterUserId" => user_id,
            "path" => file_path
          }
          |> put_optional_string(
            "computerId",
            normalize_bridge_string(payload["computerId"] || payload["agentBridgeComputerId"])
          )

        case AgentBridge.dispatch_file(user_id, request_payload) do
          :ok -> {:reply, {:ok, %{"requestId" => request_payload["requestId"]}}, socket}
          {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
        end
    end
  end

  def handle_in("agent-bridge-usage", payload, socket) when is_map(payload) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    provider = normalize_bridge_provider(payload["provider"] || payload["agentBridgeProvider"])

    if is_nil(provider) do
      {:reply, {:error, %{reason: "invalid_provider"}}, socket}
    else
      request_payload =
        %{
          "requestId" => normalize_bridge_string(payload["requestId"]) || Ecto.UUID.generate(),
          "provider" => provider,
          "chatId" => chat_id,
          "requesterUserId" => user_id
        }
        |> put_optional_string(
          "computerId",
          normalize_bridge_string(payload["computerId"] || payload["agentBridgeComputerId"])
        )

      case AgentBridge.dispatch_usage(user_id, request_payload) do
        :ok -> {:reply, {:ok, %{"requestId" => request_payload["requestId"]}}, socket}
        {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
      end
    end
  end

  def handle_in("agent-bridge-ask-response", payload, socket) when is_map(payload) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    request_id = normalize_bridge_string(payload["requestId"] || payload["request_id"])
    run_id = normalize_bridge_string(payload["runId"] || payload["run_id"])

    decision =
      case normalize_bridge_string(payload["decision"] || payload["action"]) do
        d when d in ["approve", "reject", "answer"] -> d
        _ -> "answer"
      end

    cond do
      is_nil(request_id) ->
        {:reply, {:error, %{reason: "invalid_request_id"}}, socket}

      (is_binary(run_id) or AgentDecisions.runtime_decision?(request_id)) and
          Chat.is_participant?(chat_id, user_id) ->
        handle_isolated_ask_response(request_id, run_id, payload, user_id, socket)

      true ->
        handle_bridge_ask_response(chat_id, request_id, decision, payload, user_id, socket)
    end
  end

  defp handle_isolated_ask_response(request_id, run_id, payload, user_id, socket) do
    resolved_run_id = run_id || AgentDecisions.runtime_decision_run_id(request_id)

    case AgentGateway.decision(resolved_run_id, %{
           decisionId: request_id,
           kind: "ask",
           outcome: "answer",
           answer: payload["answer"],
           actorUserId: user_id
         }) do
      {:ok, _result} -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  defp handle_bridge_ask_response(chat_id, request_id, decision, payload, user_id, socket) do
    response_payload =
      %{
        "requestId" => request_id,
        "chatId" => chat_id,
        "requesterUserId" => user_id,
        "decision" => decision
      }
      |> put_optional_string("answerEnc", normalize_bridge_string(payload["answerEnc"]))
      |> put_optional_string(
        "provider",
        normalize_bridge_provider(payload["provider"] || payload["agentBridgeProvider"])
      )
      |> put_optional_string(
        "computerId",
        normalize_bridge_string(payload["computerId"] || payload["agentBridgeComputerId"])
      )

    AgentBridge.clear_pending_ask(chat_id, request_id)

    case AgentBridge.dispatch_ask_response(user_id, response_payload) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("agent-run-control", %{"runId" => run_id, "action" => "cancel"} = payload, socket)
      when is_binary(run_id) and run_id != "" do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id

    with true <- Chat.is_participant?(chat_id, user_id),
         {:ok, run} <- AgentGateway.get_run(run_id),
         true <- run_cancel_authorized?(run, chat_id, user_id),
         {:ok, result} <- AgentGateway.cancel(run_id, payload["reason"], user_id) do
      status = result["status"] || result[:status]
      {:reply, {:ok, %{runId: run_id, status: status}}, socket}
    else
      _ -> {:reply, {:error, %{reason: "not_allowed"}}, socket}
    end
  end

  @impl true
  def handle_in("agent-run-control", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_payload"}}, socket}

  defp run_cancel_authorized?(run, chat_id, user_id) do
    run_map = run["run"] || run[:run] || run
    run_chat_id = run_map["chatId"] || run_map[:chatId]
    requester = run_map["requesterUserId"] || run_map[:requesterUserId]
    owner = run_map["ownerUserId"] || run_map[:ownerUserId]

    run_chat_id == chat_id and (user_id == requester or user_id == owner)
  end

  @impl true
  def handle_in("typing", payload, socket) do
    if VibeWeb.ChannelThrottle.check(socket.assigns.user_id, :typing) == :ok do
      broadcast_from!(socket, "typing", payload)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_in("recording", payload, socket) do
    broadcast_from!(socket, "recording", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("stop-recording", payload, socket) do
    broadcast_from!(socket, "stop-recording", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("stop-typing", payload, socket) do
    broadcast_from!(socket, "stop-typing", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("read-receipt", %{"messageId" => msg_id} = payload, socket) do
    "chat:" <> chat_id = socket.topic
    Vibe.Chat.mark_read(msg_id, socket.assigns.user_id)
    broadcast_from!(socket, "message-read", payload)
    Chat.broadcast_message_receipt(chat_id, msg_id, socket.assigns.user_id, "read")
    {:noreply, socket}
  end

  @impl true
  def handle_in("delivery-receipt", %{"messageId" => msg_id} = payload, socket) do
    "chat:" <> chat_id = socket.topic
    Vibe.Chat.mark_delivered(msg_id, socket.assigns.user_id)
    broadcast_from!(socket, "message-delivered", payload)
    Chat.broadcast_message_receipt(chat_id, msg_id, socket.assigns.user_id, "delivered")
    {:noreply, socket}
  end

  @impl true
  def handle_in("react-message", %{"messageId" => msg_id, "emoji" => emoji}, socket) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    VibeWeb.ChannelThrottle.check!(user_id, :react)

    case Chat.toggle_reaction(chat_id, msg_id, user_id, emoji) do
      {:ok, %{reactions: reactions} = result} ->
        public = Enum.map(reactions, &Map.take(&1, [:emoji, :count]))

        mutation_payload = %{
          chatId: chat_id,
          messageId: msg_id,
          reactions: public,
          actorId: user_id
        }

        broadcast!(socket, "message-reaction-updated", mutation_payload)

        {:reply, {:ok, %{action: to_string(result.action), reactions: reactions}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: engagement_error(reason)}}, socket}
    end
  catch
    {:throttled, reply} -> {:reply, {:error, reply}, socket}
  end

  @impl true
  def handle_in("react-message", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_payload"}}, socket}

  @impl true
  def handle_in("messages-viewed", %{"messageIds" => message_ids}, socket)
      when is_list(message_ids) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id

    case Chat.mark_messages_viewed(chat_id, user_id, message_ids) do
      {:ok, []} ->
        {:reply, {:ok, %{counts: []}}, socket}

      {:ok, counts} ->
        mutation_payload = %{chatId: chat_id, counts: counts}
        broadcast!(socket, "message-view-counts-updated", mutation_payload)
        {:reply, {:ok, %{counts: counts}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: engagement_error(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("messages-viewed", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_payload"}}, socket}

  @impl true
  def handle_in("media-opened", %{"messageId" => msg_id}, socket) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id

    case Chat.consume_view_once_media(chat_id, msg_id, user_id) do
      {:ok, :viewed} ->
        {:reply, {:ok, %{viewed: true}}, socket}

      {:ok, :expired} ->
        {:reply, {:ok, %{expired: true}}, socket}

      {:ok, :scheduled} ->
        {:reply, {:ok, %{scheduled: true}}, socket}

      {:ok, _message} ->
        {:reply, {:ok, %{viewed: true}}, socket}

      {:error, :not_view_once} ->
        {:reply, {:ok, %{ignored: true}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("delete-message", %{"messageId" => msg_id} = payload, socket) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    VibeWeb.ChannelThrottle.check!(user_id, :delete)

    for_everyone =
      case Map.get(payload, "forEveryone", true) do
        v when v in [true, "true", "1", 1] -> true
        _ -> false
      end

    case Vibe.Chat.delete_message(chat_id, msg_id, user_id, for_everyone) do
      {:ok, _message} ->
        mutation_payload = %{
          chatId: chat_id,
          messageId: msg_id,
          deletedBy: user_id,
          forEveryone: for_everyone
        }

        broadcast!(socket, "message-deleted", mutation_payload)

        Chat.broadcast_user_chat_event(
          chat_id,
          "message-deleted",
          mutation_payload,
          if(for_everyone, do: nil, else: [user_id])
        )

        {:reply, :ok, socket}

      {:error, :invalid_id} ->
        {:reply, {:error, %{reason: "invalid_id"}}, socket}

      {:error, :forbidden} ->
        {:reply, {:error, %{reason: "forbidden"}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "not_found"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  catch
    {:throttled, reply} -> {:reply, {:error, reply}, socket}
  end

  @impl true
  def handle_in(
        "edit-message",
        %{"messageId" => msg_id, "encryptedContent" => encrypted_content} = payload,
        socket
      ) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    VibeWeb.ChannelThrottle.check!(user_id, :edit)
    edited_at = Map.get(payload, "editedAt")

    case Vibe.Chat.edit_message(chat_id, msg_id, user_id, encrypted_content, edited_at) do
      {:ok, message} ->
        mutation_payload = %{
          chatId: chat_id,
          messageId: msg_id,
          encryptedContent: encrypted_content,
          editedAt: message.edited_at,
          editedBy: user_id,
          message:
            message
            |> Chat.client_message_payload()
            |> Chat.mirrored_message_payload()
        }

        broadcast!(socket, "message-edited", mutation_payload)
        Chat.broadcast_user_chat_event(chat_id, "message-edited", mutation_payload)

        {:reply, :ok, socket}

      {:error, :invalid_id} ->
        {:reply, {:error, %{reason: "invalid_id"}}, socket}

      {:error, :forbidden} ->
        {:reply, {:error, %{reason: "forbidden"}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "not_found"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  catch
    {:throttled, reply} -> {:reply, {:error, reply}, socket}
  end

  defp engagement_error(reason) when is_atom(reason), do: to_string(reason)
  defp engagement_error(reason), do: inspect(reason)


  @doc false
  def deliver_provider_event(agent, event_type, event_payload) do
    with {:ok, invocation} <-
           Agents.record_invocation(agent, %{
             source: "chat.interaction",
             vibe_chat_id: event_payload["chatId"],
             request_payload: event_payload,
             response_payload: %{},
             status: "completed"
           }) do
      Agents.create_delivery_event(agent, invocation, event_type, event_payload)
    end
  end

  defp provider_event_payload(
         %{"type" => "action", "actionId" => action_id, "messageId" => message_id},
         _chat_id,
         _agent_id
       )
       when is_binary(action_id) and byte_size(action_id) > 0 and is_binary(message_id) and
              byte_size(message_id) > 0 do
    {:ok, "action", %{"type" => "action", "actionId" => action_id, "messageId" => message_id}}
  end

  defp provider_event_payload(%{"type" => "call.requested"}, chat_id, agent_id) do
    {:ok, "call.requested",
     %{"type" => "call.requested", "chatId" => chat_id, "agentId" => agent_id}}
  end

  defp provider_event_payload(_payload, _chat_id, _agent_id), do: {:error, :invalid_event}

  defp maybe_dispatch_agent(chat_id, data, user_id) do
    Logger.info(
      "[ChatChannel] maybe_dispatch_agent chat_id=#{chat_id} keys=#{inspect(Map.keys(data))} agentMention=#{inspect(data["agentMention"])} mentionedAgentId=#{inspect(data["mentionedAgentId"] || data["mentioned_agent_id"])}"
    )

    agent_mention = data["agentMention"] || false
    mentioned_agent_id = data["mentionedAgentId"] || data["mentioned_agent_id"]
    room_type = Chat.get_room_type(chat_id) || "dm"
    participant_ids = Chat.get_participant_ids(chat_id)

    reserved_workers = reserved_workers_from_text(data)

    mentioned_agent_username =
      data["mentionedAgentUsername"] || data["mentioned_agent_username"] ||
        case reserved_workers do
          [%{handle: handle} | _] -> handle
          _ -> nil
        end

    agent_text = data["agentText"]
    reply_to_id = data["replyToId"] || data["reply_to_id"]

    reply_message =
      case reply_to_id do
        value when is_binary(value) and value != "" -> Chat.get_message(chat_id, value, user_id)
        _ -> nil
      end

    standalone_agent =
      cond do
        is_binary(mentioned_agent_id) and String.trim(mentioned_agent_id) != "" ->
          Agents.get_agent(mentioned_agent_id)

        is_binary(mentioned_agent_username) and String.trim(mentioned_agent_username) != "" ->
          Agents.get_agent_by_username(mentioned_agent_username)

        match?(%{from_id: _}, reply_message) ->
          Agents.get_agent_by_shadow_user(reply_message.from_id)

        true ->
          nil
      end

    local_worker =
      if standalone_agent do
        nil
      else
        (LocalAgentWorker.resolve_handle(mentioned_agent_username) ||
           LocalAgentWorker.resolve_from_message(reply_message) ||
           local_worker_for_dm(chat_id, user_id))
        |> with_mention_effort(reserved_workers)
      end

    standalone_agent =
      standalone_agent ||
        case room_type do
          "dm" ->
            chat_id
            |> Chat.get_participant_ids()
            |> Enum.reject(&(&1 == user_id))
            |> Enum.find_value(&Agents.get_agent_by_shadow_user/1)

          _ ->
            nil
        end

    group_trigger? =
      agent_mention ||
        case reply_message do
          %{from_id: from_id} ->
            normalized_from = from_id |> to_string() |> String.downcase() |> String.trim()
            normalized_agent = GroupAgent.agent_user_id() |> String.downcase() |> String.trim()
            normalized_from == normalized_agent

          _ ->
            false
        end

    attachment_context = extract_agent_attachment_context(chat_id, data, user_id)

    dispatch_text =
      case normalize_dispatch_text(agent_text, data) do
        nil -> Transcribe.voice_text(attachment_context.audio_urls)
        value -> value
      end

    team_trigger? = LocalAgentWorker.team_trigger?(dispatch_text)

    team_dispatch_text =
      if team_trigger?,
        do: LocalAgentWorker.strip_team_trigger(dispatch_text),
        else: dispatch_text

    group_agent_workers =
      if room_type != "dm" do
        LocalAgentWorker.team_workers_for_participants(participant_ids)
      else
        []
      end

    team_workers = if team_trigger?, do: group_agent_workers, else: []

    sender_is_agent? = not is_nil(LocalAgentWorker.resolve_by_agent_user_id(user_id))

    Logger.info(
      "[ChatChannel] dispatch_resolve chat_id=#{chat_id} room_type=#{room_type} reserved=#{length(reserved_workers)} team=#{team_trigger?} team_workers=#{Enum.map_join(team_workers, ",", & &1.handle)} standalone=#{not is_nil(standalone_agent)} local_worker=#{if local_worker, do: local_worker.handle, else: "nil"} dispatch_text?=#{is_binary(dispatch_text)} agent_text?=#{is_binary(agent_text) and String.trim(to_string(agent_text)) != ""} mentioned_username=#{inspect(mentioned_agent_username)} participants=#{inspect(participant_ids)}"
    )

    explicit_group_target? =
      room_type != "dm" and
        (length(reserved_workers) > 0 or
           (is_binary(mentioned_agent_username) and String.trim(mentioned_agent_username) != "") or
           match?(%{from_id: _}, reply_message))

    cond do
      room_type != "dm" and team_trigger? and length(team_workers) > 1 and
          is_binary(team_dispatch_text) ->
        spawn_team_worker_dispatches(
          chat_id,
          team_workers,
          team_dispatch_text,
          data,
          user_id
        )

      room_type != "dm" and is_nil(standalone_agent) and length(reserved_workers) > 1 and
          is_binary(dispatch_text) ->
        reserved_workers
        |> Enum.with_index()
        |> Enum.each(fn {worker, index} ->
          spawn_local_worker_dispatch(
            chat_id,
            worker,
            dispatch_text,
            data,
            "reserved_worker_group",
            user_id,
            skip_rate_limit: index > 0,
            task_id_suffix: worker.handle
          )
        end)

      room_type != "dm" and not sender_is_agent? and not explicit_group_target? and
        is_nil(standalone_agent) and is_binary(dispatch_text) and
          length(group_agent_workers) > 1 ->
        Logger.info(
          "[ChatChannel] group_default_parallel chat=#{chat_id} workers=#{Enum.map_join(group_agent_workers, ",", & &1.handle)}"
        )

        group_agent_workers
        |> Enum.with_index()
        |> Enum.each(fn {worker, index} ->
          spawn_local_worker_dispatch(
            chat_id,
            worker,
            dispatch_text,
            data,
            "group_default_parallel",
            user_id,
            skip_rate_limit: index > 0,
            note_user_turn: index == 0,
            task_id_suffix: worker.handle
          )
        end)

      room_type != "dm" and not sender_is_agent? and not explicit_group_target? and
        is_nil(standalone_agent) and is_binary(dispatch_text) and
          length(group_agent_workers) == 1 ->
        spawn_local_worker_dispatch(
          chat_id,
          hd(group_agent_workers),
          dispatch_text,
          data,
          "group_default",
          user_id
        )

      local_worker && is_binary(dispatch_text) ->
        trigger_type =
          cond do
            is_binary(mentioned_agent_username) -> "mention"
            reply_message -> "reply"
            true -> "reserved_worker"
          end

        spawn_local_worker_dispatch(
          chat_id,
          local_worker,
          dispatch_text,
          data,
          trigger_type,
          user_id
        )

      standalone_agent && is_binary(dispatch_text) ->
        trigger_type =
          cond do
            is_binary(mentioned_agent_id) or is_binary(mentioned_agent_username) -> "mention"
            reply_message -> "reply"
            true -> "dm"
          end

        spawn_standalone_dispatch(
          chat_id,
          standalone_agent,
          dispatch_text,
          data,
          attachment_context,
          trigger_type,
          user_id
        )

      group_trigger? && is_binary(dispatch_text) ->
        trigger_type = if agent_mention, do: "mention", else: "reply"

        metadata = %{
          "image_urls" => attachment_context.image_urls,
          "document_urls" => attachment_context.document_urls,
          "audio_urls" => attachment_context.audio_urls,
          "reply_to_id" => data["id"],
          "message_id" => data["id"],
          "trigger_type" => trigger_type
        }

        spawn_group_dispatch(chat_id, dispatch_text, user_id, metadata)

      true ->
        Logger.info("[ChatChannel] No agent mention detected for chat #{chat_id}")
    end
  end

  defp spawn_team_worker_dispatches(chat_id, workers, dispatch_text, data, requester_user_id) do
    team_run_id = data["id"] || Ecto.UUID.generate()
    bridge_metadata = bridge_task_metadata(data)
    supervisor? = LocalAgentWorker.team_supervisor_mode?()

    classification = LocalAgentWorker.classify_team_request(dispatch_text)
    all_agents? = LocalAgentWorker.all_agents_request?(dispatch_text)

    cond do
      # SAFETY FIRST, and deliberately mode-independent: a message that is not a work order
      classification == :chat and all_agents? and length(workers) > 1 ->
        spawn_chat_fanout_dispatches(
          chat_id,
          workers,
          dispatch_text,
          data,
          requester_user_id,
          team_run_id,
          bridge_metadata
        )

      classification == :chat ->
        spawn_chat_reply_dispatch(
          chat_id,
          workers,
          dispatch_text,
          data,
          requester_user_id,
          team_run_id,
          bridge_metadata
        )

      all_agents? ->
        spawn_supervisor_team_dispatch(
          chat_id,
          workers,
          dispatch_text,
          data,
          requester_user_id,
          team_run_id,
          bridge_metadata,
          "supervisor"
        )

      supervisor? and classification == :simple ->
        spawn_solo_visible_dispatch(
          chat_id,
          workers,
          dispatch_text,
          data,
          requester_user_id,
          team_run_id,
          bridge_metadata
        )

      true ->
        spawn_supervisor_team_dispatch(
          chat_id,
          workers,
          dispatch_text,
          data,
          requester_user_id,
          team_run_id,
          bridge_metadata,
          if(supervisor?, do: "supervisor", else: "sequential")
        )
    end
  end

  defp spawn_chat_reply_dispatch(
         chat_id,
         workers,
         dispatch_text,
         data,
         requester_user_id,
         team_run_id,
         bridge_metadata
       ) do
    responder = LocalAgentWorker.pick_chat_worker(workers) || List.first(workers)

    Logger.info(
      "[ChatChannel] chat_reply chat=#{chat_id} run=#{team_run_id} responder=#{responder.handle} (read-only, unregistered)"
    )

    spawn_local_worker_dispatch(
      chat_id,
      responder,
      dispatch_text,
      data,
      "reserved_worker_team",
      requester_user_id,
      bridge_metadata: bridge_metadata,
      note_user_turn: false,
      note_team_user_turn: true,
      team_run_id: team_run_id,
      team_workers: [responder],
      team_mode: "chat",
      lead_worker: responder.handle,
      team_role: "chat",
      suppress_visible: false,
      task_id_suffix: "chat:#{responder.handle}"
    )

    :ok
  end

  defp spawn_chat_fanout_dispatches(
         chat_id,
         workers,
         dispatch_text,
         data,
         requester_user_id,
         team_run_id,
         bridge_metadata
       ) do
    Logger.info(
      "[ChatChannel] chat_fanout chat=#{chat_id} run=#{team_run_id} workers=#{Enum.map_join(workers, ",", & &1.handle)} (read-only, unregistered)"
    )

    workers
    |> Enum.with_index()
    |> Enum.each(fn {worker, index} ->
      spawn_local_worker_dispatch(
        chat_id,
        worker,
        dispatch_text,
        data,
        "reserved_worker_team",
        requester_user_id,
        bridge_metadata: bridge_metadata,
        note_user_turn: false,
        note_team_user_turn: index == 0,
        skip_rate_limit: index > 0,
        team_run_id: team_run_id,
        team_workers: [worker],
        team_mode: "chat",
        lead_worker: worker.handle,
        team_role: "chat",
        suppress_visible: false,
        task_id_suffix: "chat:#{worker.handle}"
      )
    end)

    :ok
  end

  defp spawn_solo_visible_dispatch(
         chat_id,
         workers,
         dispatch_text,
         data,
         requester_user_id,
         team_run_id,
         bridge_metadata
       ) do
    solo = LocalAgentWorker.pick_solo_worker(workers, dispatch_text)

    registered =
      LocalAgentWorker.register_bridge_team_run(
        chat_id,
        team_run_id,
        [solo],
        dispatch_text,
        requester_user_id,
        data["id"],
        bridge_metadata,
        mode: "solo"
      )

    case registered do
      nil ->
        :ok

      solo_worker ->
        Logger.info(
          "[ChatChannel] team_run mode=solo chat=#{chat_id} run=#{team_run_id} solo=#{solo_worker.handle} pool=#{Enum.map_join(workers, ",", & &1.handle)}"
        )

        spawn_local_worker_dispatch(
          chat_id,
          solo_worker,
          dispatch_text,
          data,
          "reserved_worker_team",
          requester_user_id,
          bridge_metadata: bridge_metadata,
          note_user_turn: false,
          note_team_user_turn: true,
          team_run_id: team_run_id,
          team_workers: [solo_worker],
          team_mode: "solo",
          lead_worker: solo_worker.handle,
          team_role: "solo",
          suppress_visible: false,
          task_id_suffix: "solo:#{solo_worker.handle}"
        )

        :ok
    end
  end

  defp spawn_supervisor_team_dispatch(
         chat_id,
         workers,
         dispatch_text,
         data,
         requester_user_id,
         team_run_id,
         bridge_metadata,
         mode
       ) do
    lead_worker =
      LocalAgentWorker.register_bridge_team_run(
        chat_id,
        team_run_id,
        workers,
        dispatch_text,
        requester_user_id,
        data["id"],
        bridge_metadata,
        mode: mode
      )

    case lead_worker do
      nil ->
        :ok

      lead ->
        Logger.info(
          "[ChatChannel] team_run mode=#{mode} chat=#{chat_id} run=#{team_run_id} lead=#{lead.handle} workers=#{Enum.map_join(workers, ",", & &1.handle)}"
        )

        spawn_local_worker_dispatch(
          chat_id,
          lead,
          dispatch_text,
          data,
          "reserved_worker_team",
          requester_user_id,
          bridge_metadata: bridge_metadata,
          note_user_turn: false,
          note_team_user_turn: true,
          team_run_id: team_run_id,
          team_workers: workers,
          team_mode: mode,
          lead_worker: lead.handle,
          team_role: "lead",
          suppress_visible: false,
          task_id_suffix: if(mode == "supervisor", do: "lead:#{lead.handle}", else: nil)
        )

        :ok
    end
  end

  defp spawn_local_worker_dispatch(
         chat_id,
         worker,
         dispatch_text,
         data,
         _trigger_type,
         requester_user_id,
         opts \\ []
       ) do
    skip_rate_limit = Keyword.get(opts, :skip_rate_limit, false)
    note_user_turn? = Keyword.get(opts, :note_user_turn, true)
    note_team_user_turn? = Keyword.get(opts, :note_team_user_turn, false)
    team_run_id = Keyword.get(opts, :team_run_id)
    team_workers = Keyword.get(opts, :team_workers, [])
    task_id_suffix = Keyword.get(opts, :task_id_suffix)
    team_mode = Keyword.get(opts, :team_mode)
    lead_worker_handle = Keyword.get(opts, :lead_worker)
    team_role = Keyword.get(opts, :team_role)
    suppress_visible? = Keyword.get(opts, :suppress_visible, false) == true

    bridge_metadata =
      (Keyword.get(opts, :bridge_metadata) || bridge_task_metadata(data))
      |> resolve_provider_model(worker.handle)

    base_task_id =
      case data["id"] do
        id when is_binary(id) and id != "" -> id
        _ -> Ecto.UUID.generate()
      end

    task_id =
      case task_id_suffix do
        suffix when is_binary(suffix) and suffix != "" -> "#{base_task_id}:#{suffix}"
        _ -> base_task_id
      end

    cond do
      not LocalAgentWorker.dispatch_allowed?(worker, requester_user_id) ->
        maybe_clear_team_run(chat_id, team_run_id)

        Logger.warning(
          "[ChatChannel] local worker blocked: user=#{requester_user_id} not in VIBE_AGENT_WORKER_ALLOWED_USERS"
        )

        :ok

      not skip_rate_limit and not LocalAgentWorker.allow_request?(requester_user_id) ->
        maybe_clear_team_run(chat_id, team_run_id)

        Logger.info(
          "[ChatChannel] local worker cooldown user=#{requester_user_id} worker=#{worker.handle} chat=#{chat_id}"
        )

        :ok

      not LocalAgentWorker.server_runtime?(worker) and AgentBridge.paired?(requester_user_id) ->
        reply_to_id = data["id"]

        team_meta =
          local_worker_team_metadata(
            worker,
            team_run_id,
            team_workers,
            team_mode: team_mode,
            lead_worker: lead_worker_handle,
            team_role: team_role,
            suppress_visible: suppress_visible?
          )

        run = fn ->
          bridge_prompt =
            if is_binary(team_run_id) do
              LocalAgentWorker.build_team_bridge_prompt(
                chat_id,
                worker,
                dispatch_text,
                requester_user_id,
                team_workers,
                team_run_id,
                team_mode: team_mode || "supervisor",
                lead_worker: lead_worker_handle,
                team_role: team_role
              )
            else
              LocalAgentWorker.build_bridge_prompt(
                chat_id,
                worker,
                dispatch_text,
                requester_user_id,
                bridge_metadata: bridge_metadata
              )
            end

          task_payload =
            %{
              "provider" => worker.handle,
              "chatId" => chat_id,
              "taskId" => task_id,
              "prompt" => bridge_prompt,
              "replyToId" => reply_to_id,
              "requesterUserId" => requester_user_id
            }
            |> Map.merge(team_meta)
            |> Map.merge(bridge_metadata)

          broadcast_agent_activity(
            chat_id,
            worker.agent_user_id,
            "#{worker.label} working...",
            "running"
          )

          case dispatch_bridge_task_with_reconnect_grace(requester_user_id, task_payload) do
            :ok ->
              note_bridge_dispatch_turn(
                chat_id,
                worker,
                dispatch_text,
                requester_user_id,
                note_user_turn?,
                note_team_user_turn?,
                team_run_id,
                team_workers
              )

              Logger.info(
                "[ChatChannel] dispatched @#{worker.handle} to bridge user=#{requester_user_id} chat=#{chat_id}"
              )

            {:error, reason} ->
              maybe_clear_team_run(chat_id, team_run_id)
              stop_agent_activity(chat_id, worker.agent_user_id)

              LocalAgentWorker.post_notice(
                worker,
                chat_id,
                bridge_dispatch_failure_notice(worker, reason),
                requester_user_id,
                reply_to_id
              )
          end
        end

        case Task.Supervisor.start_child(Vibe.AI.WorkerTaskSupervisor, run) do
          {:error, :max_children} ->
            maybe_clear_team_run(chat_id, team_run_id)

            LocalAgentWorker.post_notice(
              worker,
              chat_id,
              "#{worker.label} is busy with other tasks right now. Please try again in a moment.",
              requester_user_id,
              data["id"]
            )

          _ ->
            :ok
        end

      LocalAgentWorker.enabled?() ->
        run = fn ->
          broadcast_agent_activity(
            chat_id,
            worker.agent_user_id,
            "#{worker.label} working...",
            "running"
          )

          try do
            case LocalAgentWorker.handle_chat_message(
                   worker,
                   chat_id,
                   dispatch_text,
                   reply_to_id: data["id"],
                   requester_user_id: requester_user_id,
                   bridge_metadata: bridge_metadata,
                   progress_callback: fn event ->
                     broadcast_agent_activity(
                       chat_id,
                       worker.agent_user_id,
                       Map.get(event, "label") || "#{worker.label} working...",
                       "running",
                       Map.get(event, "tool")
                     )
                   end
                 ) do
              {:ok, _response} ->
                Logger.info(
                  "[ChatChannel] Local worker responded chat_id=#{chat_id} provider=#{worker.handle}"
                )

              {:error, reason} ->
                Logger.error(
                  "[ChatChannel] Local worker dispatch failed chat_id=#{chat_id} provider=#{worker.handle} reason=#{inspect(reason)}"
                )
            end
          after
            stop_agent_activity(chat_id, worker.agent_user_id)
          end
        end

        case Task.Supervisor.start_child(Vibe.AI.WorkerTaskSupervisor, run) do
          {:error, :max_children} ->
            LocalAgentWorker.post_notice(
              worker,
              chat_id,
              "#{worker.label} is busy with other tasks right now. Please try again in a moment.",
              requester_user_id,
              data["id"]
            )

          _ ->
            :ok
        end

      true ->
        LocalAgentWorker.post_notice(
          worker,
          chat_id,
          "Connect your computer to run @#{worker.handle}. Open #{worker.label} in Vibe and tap Connect to pair this chat with your machine.",
          requester_user_id,
          data["id"]
        )
    end
  end

  defp maybe_clear_team_run(_chat_id, nil), do: :ok

  defp maybe_clear_team_run(chat_id, team_run_id),
    do: LocalAgentWorker.clear_bridge_team_run(chat_id, team_run_id)

  defp dispatch_bridge_task_with_reconnect_grace(requester_user_id, task_payload) do
    AgentBridge.dispatch_task(requester_user_id, task_payload)
  end

  defp note_bridge_dispatch_turn(
         chat_id,
         worker,
         dispatch_text,
         requester_user_id,
         note_user_turn?,
         note_team_user_turn?,
         team_run_id,
         team_workers
       ) do
    cond do
      note_team_user_turn? ->
        LocalAgentWorker.note_bridge_team_user_turn(
          chat_id,
          team_workers,
          dispatch_text,
          requester_user_id,
          team_run_id
        )

      note_user_turn? ->
        LocalAgentWorker.note_bridge_user_turn(
          chat_id,
          worker,
          dispatch_text,
          requester_user_id
        )

      true ->
        :ok
    end
  end

  defp bridge_dispatch_failure_notice(_worker, :computer_required),
    do: "Choose which connected computer should run this task before sending."

  defp bridge_dispatch_failure_notice(_worker, :computer_offline),
    do: "The selected computer is offline. Pick another connected computer or reconnect it."

  defp bridge_dispatch_failure_notice(_worker, :offline),
    do:
      "Your paired computer is still reconnecting, so this task was not sent. Keep the chat open and try again in a moment."

  defp bridge_dispatch_failure_notice(worker, _reason),
    do: "Your computer just went offline. Reconnect it to run @#{worker.handle} tasks."

  defp local_worker_team_metadata(_worker, nil, _team_workers, _opts), do: %{}

  defp local_worker_team_metadata(worker, team_run_id, team_workers, opts \\ []) do
    mode = Keyword.get(opts, :team_mode) || "group_team"
    lead = Keyword.get(opts, :lead_worker)
    role = Keyword.get(opts, :team_role)
    suppress? = Keyword.get(opts, :suppress_visible, false) == true

    %{
      "teamMode" => mode,
      "teamRunId" => team_run_id,
      "teamWorker" => worker.handle,
      "teamWorkers" => Enum.map(team_workers, & &1.handle)
    }
    |> then(fn m -> if is_binary(lead), do: Map.put(m, "leadWorker", lead), else: m end)
    |> then(fn m -> if is_binary(role), do: Map.put(m, "teamRole", role), else: m end)
    |> then(fn m -> if suppress?, do: Map.put(m, "suppressVisible", true), else: m end)
  end

  defp spawn_standalone_dispatch(
         chat_id,
         agent,
         dispatch_text,
         data,
         attachment_context,
         trigger_type,
         requester_user_id,
         opts \\ []
       ) do
    parent_run_id = opts[:parent_run_id]

    Task.start(fn ->
      broadcast_agent_activity(chat_id, agent.agent_user_id, "Thinking...", "running")

      try do
        attachments = attachment_context_to_attachments(attachment_context)

        cond do
          AgentGateway.kill_switch?() ->
            post_kill_switch_notice(agent, chat_id, data["id"])

          AgentGateway.execution_mode_for(agent) == "isolated" and AgentGateway.enabled?() ->
            dispatch_isolated(
              agent,
              chat_id,
              dispatch_text,
              attachments,
              data,
              requester_user_id,
              parent_run_id,
              trigger_type
            )

          true ->
            dispatch_embedded(agent, chat_id, dispatch_text, attachments, data, requester_user_id)
        end
      after
        stop_agent_activity(chat_id, agent.agent_user_id)
      end
    end)
  end

  defp dispatch_isolated(
         agent,
         chat_id,
         dispatch_text,
         attachments,
         data,
         requester_user_id,
         parent_run_id,
         trigger_type
       ) do
    case AgentGateway.start_run(%{
           agent: agent,
           chat_id: chat_id,
           requester_user_id: requester_user_id,
           text: dispatch_text,
           attachments: attachments,
           reply_to_id: data["id"],
           parent_run_id: parent_run_id,
           source: if(parent_run_id, do: "handoff", else: "chat")
         }) do
      {:ok, run} ->
        if is_map(run) and reply_output_mode(agent, data, attachments) == "voice" do
          Vibe.AgentRelay.expect_voice_reply(run["runId"], data["id"])
        end

        Logger.info(
          "[ChatChannel] isolated run started chat_id=#{chat_id} agent_id=#{agent.id}"
        )

      {:error, :unreachable} ->
        Logger.warning(
          "[ChatChannel] agent-runtime unreachable, falling back to embedded chat_id=#{chat_id} agent_id=#{agent.id}"
        )

        dispatch_embedded(agent, chat_id, dispatch_text, attachments, data, requester_user_id)

      {:error, :kill_switch} ->
        post_kill_switch_notice(agent, chat_id, data["id"])

      {:error, {:http_error, 503, %{"error" => "kill_switch"}}} ->
        post_kill_switch_notice(agent, chat_id, data["id"])

      {:error, :agent_credits_exhausted} ->
        post_credits_notice(agent, chat_id, data["id"])

      {:error, reason} ->
        Logger.error(
          "[ChatChannel] isolated run failed chat_id=#{chat_id} agent_id=#{agent.id} trigger=#{trigger_type} reason=#{inspect(reason)}"
        )
    end
  end

  defp dispatch_embedded(agent, chat_id, dispatch_text, attachments, data, requester_user_id) do
    case StandaloneAgent.handle_chat_message(
           agent,
           chat_id,
           dispatch_text,
           attachments: attachments,
           output_mode: reply_output_mode(agent, data, attachments),
           reply_to_id: data["id"],
           requester_user_id: requester_user_id
         ) do
      {:ok, _response} ->
        Logger.info(
          "[ChatChannel] Standalone agent responded chat_id=#{chat_id} agent_id=#{agent.id}"
        )

      {:error, :agent_credits_exhausted} ->
        post_credits_notice(agent, chat_id, data["id"])

      {:error, reason} ->
        Logger.error(
          "[ChatChannel] Standalone agent dispatch failed chat_id=#{chat_id} agent_id=#{agent.id} reason=#{inspect(reason)}"
        )
    end
  end

  defp post_kill_switch_notice(agent, chat_id, reply_to_id) do
    outputs = [
      %{"type" => "text", "text" => "Agents are paused by the operator", "metadata" => %{}}
    ]

    _ = StandaloneAgent.deliver_outputs(agent, chat_id, outputs, reply_to_id)
    :ok
  end

  defp post_credits_notice(agent, chat_id, reply_to_id) do
    outputs = [
      %{
        "type" => "text",
        "text" => "This agent is out of usage credits for the month.",
        "metadata" => %{}
      }
    ]

    _ = StandaloneAgent.deliver_outputs(agent, chat_id, outputs, reply_to_id)
    :ok
  end

  @doc """
  Starts a standalone-agent run for a `handoff_to_agent` target (docs/agent-platform-v1.md
  §3.8), reusing the same kill-switch/execution-mode routing as a normal dispatch.
  """
  def dispatch_agent_mention(chat_id, %Agent{} = target_agent, opts) when is_list(opts) do
    text = Keyword.get(opts, :text, "") || ""
    parent_run_id = Keyword.get(opts, :parent_run_id)
    reply_to_id = Keyword.get(opts, :reply_to_id) || Ecto.UUID.generate()

    spawn_standalone_dispatch(
      chat_id,
      target_agent,
      text,
      %{"id" => reply_to_id},
      %{image_urls: [], document_urls: [], audio_urls: []},
      "handoff",
      nil,
      parent_run_id: parent_run_id
    )
  end

  defp spawn_group_dispatch(chat_id, dispatch_text, user_id, metadata) do
    Task.start(fn ->
      broadcast_agent_activity(chat_id, GroupAgent.agent_user_id(), "Thinking...", "running")

      try do
        case GroupAgent.handle_mention(chat_id, dispatch_text, user_id, metadata) do
          {:ok, _response} ->
            Logger.info("[ChatChannel] Agent responded in chat #{chat_id}")

          {:error, :no_agent} ->
            Logger.debug("[ChatChannel] No agent configured for chat #{chat_id}")

          {:error, reason} ->
            Logger.error(
              "[ChatChannel] Agent dispatch failed for chat #{chat_id}: #{inspect(reason)}"
            )
        end
      after
        stop_agent_activity(chat_id, GroupAgent.agent_user_id())
      end
    end)
  end

  defp normalize_dispatch_text(agent_text, data) do
    value =
      cond do
        is_binary(agent_text) and String.trim(agent_text) != "" ->
          agent_text

        true ->
          data["pushPreview"] || data["textPreview"] || data["text"] || data["body"]
      end

    case value do
      text when is_binary(text) ->
        trimmed = String.trim(text)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp reserved_workers_from_text(data) do
    text = data["pushPreview"] || data["textPreview"] || data["text"] || data["body"]
    LocalAgentWorker.extract_reserved_mentions(text)
  end

  # The mention carries any pinned thinking level; a handle re-resolved from the roster does not.
  defp with_mention_effort(nil, _reserved), do: nil

  defp with_mention_effort(worker, reserved) do
    case Enum.find(reserved, &(&1.handle == worker.handle)) do
      %{effort_directive: level} -> Map.put(worker, :effort_directive, level)
      _ -> worker
    end
  end

  defp bridge_task_metadata(data) do
    metadata =
      case data["metadata"] || data["meta"] do
        value when is_map(value) -> value
        _ -> %{}
      end

    %{}
    |> put_optional_string(
      "cwd",
      metadata["agentBridgeCwd"] || metadata["agent_bridge_cwd"] || data["agentBridgeCwd"]
    )
    |> put_optional_string(
      "repoId",
      metadata["agentBridgeRepoId"] || metadata["agent_bridge_repo_id"] ||
        data["agentBridgeRepoId"]
    )
    |> put_optional_string(
      "repoName",
      metadata["agentBridgeRepoName"] || metadata["agent_bridge_repo_name"] ||
        data["agentBridgeRepoName"]
    )
    |> put_optional_string(
      "computerId",
      metadata["agentBridgeComputerId"] || metadata["agent_bridge_computer_id"] ||
        data["agentBridgeComputerId"] || data["computerId"]
    )
    |> put_optional_string(
      "workMode",
      metadata["agentBridgeWorkMode"] || metadata["agent_bridge_work_mode"] ||
        data["agentBridgeWorkMode"]
    )
    |> put_optional_string(
      "model",
      metadata["agentBridgeModel"] || metadata["agent_bridge_model"] || data["agentBridgeModel"]
    )
    |> put_optional_string(
      "advisor",
      metadata["agentBridgeAdvisor"] || metadata["agent_bridge_advisor"] ||
        data["agentBridgeAdvisor"]
    )
    |> put_provider_models(
      metadata["agentBridgeModels"] || metadata["agent_bridge_models"] ||
        data["agentBridgeModels"]
    )
    |> put_provider_advisors(
      metadata["agentBridgeAdvisors"] || metadata["agent_bridge_advisors"] ||
        data["agentBridgeAdvisors"]
    )
    |> put_provider_efforts(
      metadata["agentBridgeEfforts"] || metadata["agent_bridge_efforts"] ||
        data["agentBridgeEfforts"]
    )
    |> put_optional_string(
      "intelligence",
      metadata["agentBridgeIntelligence"] || metadata["agent_bridge_intelligence"] ||
        data["agentBridgeIntelligence"]
    )
    |> put_optional_string(
      "speed",
      metadata["agentBridgeSpeed"] || metadata["agent_bridge_speed"] || data["agentBridgeSpeed"]
    )
    |> put_optional_string(
      "reasoningEffort",
      metadata["agentBridgeReasoningEffort"] || metadata["agent_bridge_reasoning_effort"] ||
        data["agentBridgeReasoningEffort"]
    )
    |> put_optional_string(
      "resumeSessionId",
      metadata["agentBridgeResumeSessionId"] || metadata["agent_bridge_resume_session_id"] ||
        data["agentBridgeResumeSessionId"]
    )
    |> put_optional_string_list(
      "attachmentsEnc",
      metadata["agentBridgeAttachmentsEnc"] || metadata["agent_bridge_attachments_enc"] ||
        data["agentBridgeAttachmentsEnc"]
    )
  end

  defp normalize_control_action(value) do
    value = normalize_bridge_string(value)

    case value && String.downcase(value) do
      action when action in ["cancel", "stop", "revert"] -> action
      _ -> nil
    end
  end

  defp normalize_bridge_provider(value) do
    value = normalize_bridge_string(value)

    case value && String.downcase(value) do
      provider when provider in ["claude", "codex", "grok", "agy"] -> provider
      "antigravity" -> "agy"
      _ -> nil
    end
  end

  defp normalize_bridge_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_bridge_string(_), do: nil

  defp put_optional_string(map, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> map
      trimmed -> Map.put(map, key, trimmed)
    end
  end

  defp put_optional_string(map, _key, _value), do: map

  defp put_provider_models(map, models) when is_map(models) do
    cleaned =
      models
      |> Enum.flat_map(fn {provider, model} ->
        with true <- is_binary(provider),
             model when is_binary(model) <- model,
             trimmed when trimmed != "" <- String.trim(model) do
          [{String.downcase(provider), trimmed}]
        else
          _ -> []
        end
      end)
      |> Map.new()

    if map_size(cleaned) > 0, do: Map.put(map, "models", cleaned), else: map
  end

  defp put_provider_models(map, _models), do: map

  defp put_provider_advisors(map, advisors) when is_map(advisors) do
    cleaned =
      advisors
      |> Enum.flat_map(fn {provider, advisor} ->
        with true <- is_binary(provider),
             advisor when is_binary(advisor) <- advisor,
             trimmed when trimmed != "" <- String.trim(advisor) do
          [{String.downcase(provider), trimmed}]
        else
          _ -> []
        end
      end)
      |> Map.new()

    if map_size(cleaned) > 0, do: Map.put(map, "advisors", cleaned), else: map
  end

  defp put_provider_advisors(map, _advisors), do: map

  defp put_provider_efforts(map, efforts) when is_map(efforts) do
    cleaned =
      efforts
      |> Enum.flat_map(fn {handle, effort} ->
        with true <- is_binary(handle),
             effort when is_binary(effort) <- effort,
             trimmed when trimmed != "" <- String.trim(effort) do
          [{String.downcase(handle), String.downcase(trimmed)}]
        else
          _ -> []
        end
      end)
      |> Map.new()

    if map_size(cleaned) > 0, do: Map.put(map, "efforts", cleaned), else: map
  end

  defp put_provider_efforts(map, _efforts), do: map

  defp resolve_provider_model(bridge_metadata, provider) do
    {models, rest} = Map.pop(bridge_metadata, "models")
    {advisors, rest} = Map.pop(rest, "advisors")
    {efforts, rest} = Map.pop(rest, "efforts")
    provider_key = String.downcase(to_string(provider))

    rest =
      case is_map(models) && models[provider_key] do
        model when is_binary(model) and model != "" -> Map.put(rest, "model", model)
        _ -> rest
      end

    rest =
      case is_map(efforts) && efforts[provider_key] do
        effort when is_binary(effort) and effort != "" ->
          Map.put(rest, "reasoningEffort", effort)

        _ ->
          rest
      end

    case is_map(advisors) && advisors[provider_key] do
      advisor when is_binary(advisor) and advisor != "" -> Map.put(rest, "advisor", advisor)
      _ -> rest
    end
  end

  defp put_optional_positive_integer(map, key, value) when is_integer(value) and value > 0 do
    Map.put(map, key, min(value, 600))
  end

  defp put_optional_positive_integer(map, key, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> put_optional_positive_integer(map, key, parsed)
      _ -> map
    end
  end

  defp put_optional_positive_integer(map, _key, _value), do: map

  defp put_optional_string_list(map, key, value) when is_list(value) do
    case Enum.filter(value, &(is_binary(&1) and &1 != "")) do
      [] -> map
      strings -> Map.put(map, key, strings)
    end
  end

  defp put_optional_string_list(map, _key, _value), do: map

  defp local_worker_for_dm(chat_id, user_id) do
    case Chat.get_room_type(chat_id) do
      "dm" ->
        chat_id
        |> Chat.get_participant_ids()
        |> Enum.reject(&(&1 == user_id))
        |> Enum.find_value(&LocalAgentWorker.resolve_by_agent_user_id/1)

      _ ->
        nil
    end
  end

  defp message_metadata_for_persistence(data, standalone_agent) do
    base_metadata =
      case data["metadata"] do
        value when is_map(value) -> Map.drop(value, @inline_attachment_keys)
        _ -> %{}
      end

    base_metadata =
      case durable_media_url(base_metadata["mediaUrl"] || base_metadata["media_url"]) do
        nil ->
          base_metadata
          |> Map.delete("mediaUrl")
          |> Map.delete("media_url")
          |> Map.delete("localMediaUrl")
          |> Map.delete("local_media_url")

        remote ->
          base_metadata
          |> Map.put("mediaUrl", remote)
          |> Map.delete("localMediaUrl")
          |> Map.delete("local_media_url")
      end

    if standalone_agent do
      case normalize_dispatch_text(data["agentText"], data) do
        text when is_binary(text) ->
          Map.put(
            base_metadata,
            "agentInputCiphertext",
            AgentMessageCrypto.encrypt_for_storage(text)
          )

        _ ->
          base_metadata
      end
    else
      base_metadata
    end
  end

  defp strip_inline_agent_attachments(%{} = payload) do
    payload
    |> Map.drop(@inline_attachment_keys)
    |> case do
      %{"metadata" => %{} = meta} = stripped ->
        Map.put(stripped, "metadata", Map.drop(meta, @inline_attachment_keys))

      stripped ->
        stripped
    end
  end

  defp strip_inline_agent_attachments(payload), do: payload

  defp durable_media_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    cond do
      trimmed == "" ->
        nil

      String.starts_with?(trimmed, "file:") ->
        nil

      String.starts_with?(trimmed, "/") ->
        nil

      String.starts_with?(trimmed, "http://") or String.starts_with?(trimmed, "https://") ->
        trimmed

      true ->
        Logger.info("[MediaDrop] reject non-http media_url=#{String.slice(trimmed, 0, 80)}")
        nil
    end
  end

  defp durable_media_url(_), do: nil

  @doc "Public so Vibe.AgentRelay can keep the typing/'Thinking...' indicator in sync for isolated runs."
  def broadcast_agent_activity(chat_id, agent_user_id, label, status, tool \\ nil) do
    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "typing", %{
      "userId" => agent_user_id,
      "isAgent" => true
    })

    payload =
      %{
        "userId" => agent_user_id,
        "isAgent" => true,
        "label" => label,
        "status" => status
      }
      |> then(fn payload ->
        case tool do
          value when is_binary(value) and value != "" -> Map.put(payload, "tool", value)
          _ -> payload
        end
      end)

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-progress", payload)
  end

  @doc "Public so Vibe.AgentRelay can clear the typing indicator when an isolated run ends."
  def stop_agent_activity(chat_id, agent_user_id) do
    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-progress", %{
      "userId" => agent_user_id,
      "isAgent" => true,
      "status" => "done"
    })

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "stop-typing", %{
      "userId" => agent_user_id,
      "isAgent" => true
    })
  end

  defp reply_output_mode(agent, data, attachments) do
    voice_in? =
      is_nil(normalize_dispatch_text(data["agentText"], data)) and
        Enum.any?(attachments, &(&1[:type] == "voice"))

    if voice_in? and "voice" in (agent.output_modes || []), do: "voice"
  end

  defp attachment_context_to_attachments(%{
         image_urls: image_urls,
         document_urls: document_urls,
         audio_urls: audio_urls
       }) do
    image_urls
    |> Enum.map(&%{type: "image", url: &1})
    |> Kernel.++(Enum.map(document_urls, &%{type: "file", url: &1}))
    |> Kernel.++(Enum.map(audio_urls, &%{type: "voice", url: &1}))
  end

  defp extract_agent_attachment_context(chat_id, data, user_id) do
    seeded_images = normalize_urls(data["agentImageUrls"] || data["agent_image_urls"])
    seeded_documents = normalize_urls(data["agentDocumentUrls"] || data["agent_document_urls"])
    seeded_audio = normalize_urls(data["agentAudioUrls"] || data["agent_audio_urls"])

    from_current =
      classify_attachment(
        data["type"] || data["messageType"] || data["message_type"],
        data["mediaUrl"] || data["media_url"]
      )

    reply_media =
      case data["replyToId"] || data["reply_to_id"] do
        reply_id when is_binary(reply_id) and reply_id != "" ->
          case Chat.get_message(chat_id, reply_id, user_id) do
            nil -> nil
            message -> classify_attachment(message.type, message.media_url)
          end

        _ ->
          nil
      end

    image_urls =
      seeded_images
      |> maybe_add_classified_attachment(from_current, :image)
      |> maybe_add_classified_attachment(reply_media, :image)
      |> Enum.uniq()

    document_urls =
      seeded_documents
      |> maybe_add_classified_attachment(from_current, :document)
      |> maybe_add_classified_attachment(reply_media, :document)
      |> Enum.uniq()

    audio_urls =
      seeded_audio
      |> maybe_add_classified_attachment(from_current, :audio)
      |> maybe_add_classified_attachment(reply_media, :audio)
      |> Enum.uniq()

    %{image_urls: image_urls, document_urls: document_urls, audio_urls: audio_urls}
  end

  defp normalize_urls(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_urls(value) when is_binary(value), do: normalize_urls([value])
  defp normalize_urls(_), do: []

  defp maybe_add_classified_attachment(urls, {:image, url}, :image), do: [url | urls]
  defp maybe_add_classified_attachment(urls, {:document, url}, :document), do: [url | urls]
  defp maybe_add_classified_attachment(urls, {:audio, url}, :audio), do: [url | urls]
  defp maybe_add_classified_attachment(urls, _attachment, _kind), do: urls

  defp classify_attachment(raw_type, raw_url) do
    type = normalize_type(raw_type)
    url = normalize_url(raw_url)

    cond do
      is_nil(url) ->
        nil

      type in ["image", "gif", "sticker"] ->
        {:image, url}

      type in ["file", "document", "pdf"] ->
        {:document, url}

      type in ["voice", "audio", "music"] ->
        {:audio, url}

      image_url?(url) ->
        {:image, url}

      document_url?(url) ->
        {:document, url}

      audio_url?(url) ->
        {:audio, url}

      true ->
        nil
    end
  end

  defp normalize_type(raw_type) do
    raw_type
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_url(raw_url) when is_binary(raw_url) do
    trimmed = String.trim(raw_url)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_url(_), do: nil

  defp image_url?(url) when is_binary(url) do
    lower = String.downcase(url)

    Enum.any?(
      [".png", ".jpg", ".jpeg", ".webp", ".gif", ".heic", ".bmp"],
      &String.contains?(lower, &1)
    )
  end

  defp document_url?(url) when is_binary(url) do
    lower = String.downcase(url)

    Enum.any?(
      [".pdf", ".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx", ".txt", ".rtf", ".md"],
      &String.contains?(lower, &1)
    )
  end

  defp audio_url?(url) when is_binary(url) do
    lower = String.downcase(url)

    Enum.any?(
      [".mp3", ".m4a", ".aac", ".wav", ".ogg", ".oga", ".opus", ".flac"],
      &String.contains?(lower, &1)
    )
  end

  defp enforce_sender_identity(payload, user_id) when is_map(payload) do
    payload
    |> Map.put("fromId", user_id)
    |> Map.put("from_id", user_id)
  end

  defp deobfuscate(%{"d" => encoded}) do
    encoded
    |> Base.decode64!(ignore: :whitespace)
    |> Jason.decode!()
  end

  defp deobfuscate(map), do: map
end
