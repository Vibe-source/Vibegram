defmodule Vibe.AI.StandaloneAgent do
  @moduledoc false

  require Logger

  alias Vibe.AgentUsage
  alias Vibe.Chat
  alias Vibe.Notifications
  alias Vibe.Agent, as: AgentSchema
  alias Vibe.AI.Agent, as: ChatAgent
  alias Vibe.AI.TTS
  alias Vibe.Chat.AgentMessageCrypto

  @conversation_history_limit 12

  def invoke(%AgentSchema{} = agent, params) when is_map(params) do
    response_mode = normalize_response_mode(params["responseMode"] || params["response_mode"])
    message = normalize_string(params["message"])
    vibe_chat_id = normalize_string(params["vibeChatId"] || params["vibe_chat_id"])
    attachments = normalize_attachments(params["attachments"])
    requested_output_mode = normalize_string(params["outputMode"] || params["output_mode"])
    reply_to_id = normalize_string(params["replyToId"] || params["reply_to_id"])
    requester_user_id = normalize_string(params["requesterUserId"] || params["requester_user_id"])
    provider_content = provider_content_from_params(params)

    cond do
      agent.status != "published" ->
        {:error, :agent_unavailable}

      message == nil ->
        {:error, :missing_message}

      response_mode in ["send", "post"] and is_nil(vibe_chat_id) ->
        {:error, :missing_chat_id}

      response_mode in ["send", "post"] and
          not Chat.is_participant?(vibe_chat_id, agent.agent_user_id) ->
        {:error, :chat_not_attached}

      response_mode == "post" ->
        agent_turn_id =
          normalize_string(params["agentTurnId"] || params["agent_turn_id"]) ||
            Ecto.UUID.generate()

        outputs =
          []
          |> maybe_append_text_output(message, %{"verbatim" => true})
          |> finalize_batch(agent_turn_id: agent_turn_id)
          |> put_provider_content_on_outputs(provider_content)

        with {:ok, deliveries} <-
               maybe_deliver(agent, vibe_chat_id, outputs, "send", reply_to_id) do
          {:ok,
           %{
             outputs: outputs,
             vibe_deliveries: deliveries,
             status: response_status(outputs),
             agent_turn_id: agent_turn_id
           }}
        end

      true ->
        agent_turn_id =
          normalize_string(params["agentTurnId"] || params["agent_turn_id"]) ||
            Ecto.UUID.generate()

        with :ok <- AgentUsage.check_entitlement(agent.owner_user_id),
             {:ok, scoped_agent} <-
               delivery_scoped_agent(agent, response_mode, vibe_chat_id, requester_user_id),
             {:ok, outputs} <-
               generate_outputs(
                 scoped_agent,
                 message,
                 attachments,
                 requested_output_mode,
                 vibe_chat_id,
                 requester_user_id
               ) do
          outputs =
            finalize_batch(outputs,
              agent_turn_id: agent_turn_id
            )

          outputs = put_provider_content_on_outputs(outputs, provider_content)

          AgentUsage.record_embedded(
            agent,
            agent_turn_id,
            VibeContracts.ModelRates.estimate_tokens(message),
            VibeContracts.ModelRates.estimate_tokens(Enum.map_join(outputs, " ", &(&1["text"] || "")))
          )

          with {:ok, deliveries} <-
                 maybe_deliver(scoped_agent, vibe_chat_id, outputs, response_mode, reply_to_id) do
            {:ok,
             %{
               outputs: outputs,
               vibe_deliveries: deliveries,
               status: response_status(outputs),
               agent_turn_id: agent_turn_id
             }}
          end
        end
    end
  end

  def handle_chat_message(%AgentSchema{} = agent, chat_id, message, opts \\ []) do
    params = %{
      "message" => message,
      "responseMode" => "send",
      "vibeChatId" => chat_id,
      "outputMode" => Keyword.get(opts, :output_mode),
      "replyToId" => Keyword.get(opts, :reply_to_id),
      "attachments" => Keyword.get(opts, :attachments, []),
      "requesterUserId" => Keyword.get(opts, :requester_user_id)
    }

    invoke(agent, params)
  end

  defp delivery_scoped_agent(agent, "send", chat_id, requester_user_id) do
    with {:ok, policy} <- Chat.effective_agent_policy(chat_id, agent, requester_user_id) do
      {:ok,
       %{
         agent
         | enabled_tools: Map.get(policy, :enabled_tools) || [],
           output_modes: Map.get(policy, :output_modes) || [],
           system_prompt:
             scoped_system_prompt(agent.system_prompt, Map.get(policy, :permissions) || %{}),
           admin_mode: Map.get(policy, :admin_mode, false)
       }}
    end
  end

  defp delivery_scoped_agent(agent, _response_mode, _chat_id, _requester_user_id),
    do: {:ok, agent}

  defp scoped_system_prompt(base_prompt, permissions) do
    channel_instructions =
      normalize_string(permissions["instructions"] || permissions[:instructions])

    [
      base_prompt,
      channel_instructions && "Channel-specific instructions: #{channel_instructions}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> case do
      "" -> nil
      prompt -> prompt
    end
  end

  defp generate_outputs(
         agent,
         message,
         attachments,
         requested_output_mode,
         vibe_chat_id,
         requester_user_id
       ) do
    image_urls =
      attachments
      |> Enum.filter(&(&1.type == "image"))
      |> Enum.map(& &1.url)

    message_with_attachment_context =
      message
      |> append_attachment_context(build_attachment_context(attachments))

    conversation_history =
      recent_chat_history(vibe_chat_id, requester_user_id, agent.agent_user_id)

    turn_memory = turn_memory_from_chat(vibe_chat_id, requester_user_id, agent.agent_user_id)

    has_prior_messages = chat_has_prior_messages?(vibe_chat_id, requester_user_id)
    system_prompt = build_system_prompt(agent, has_prior_messages)

    {:ok, collected} =
      Elixir.Agent.start_link(fn -> %{text: "", outputs: [], text_metadata: %{}} end)

    callback = fn
      %{type: :text, content: chunk} ->
        Elixir.Agent.update(collected, fn acc -> %{acc | text: acc.text <> chunk} end)

      %{type: :tool_result, tool: tool_name, result: result} ->
        Elixir.Agent.update(collected, fn acc ->
          next_outputs = merge_outputs(acc.outputs, tool_outputs_from_result(tool_name, result))

          next_text_metadata =
            acc.text_metadata
            |> Map.merge(text_metadata_from_result(tool_name, result))

          %{acc | outputs: next_outputs, text_metadata: next_text_metadata}
        end)

      _ ->
        :ok
    end

    try do
      with {:ok, final_text} <-
             stream_agent_text(
               message_with_attachment_context,
               callback,
               image_urls,
               vibe_chat_id,
               agent.owner_user_id,
               requester_user_id,
               agent.id,
               agent.model_provider,
               agent.model_id,
               system_prompt,
               agent.enabled_tools || [],
               conversation_history,
               turn_memory,
               agent.admin_mode,
               mcp_tool_specs(agent)
             ) do
        accumulated = Elixir.Agent.get(collected, & &1)

        outputs =
          finalize_outputs(
            agent,
            final_text,
            accumulated.outputs,
            accumulated.text_metadata,
            requested_output_mode
          )

        {:ok, outputs}
      end
    after
      Elixir.Agent.stop(collected)
    end
  end

  defp maybe_deliver(_agent, _chat_id, _outputs, "reply", _reply_to_id), do: {:ok, []}

  defp maybe_deliver(agent, chat_id, outputs, "send", reply_to_id) do
    base_timestamp = :os.system_time(:millisecond)

    deliveries =
      outputs
      |> Enum.with_index()
      |> Enum.map(fn {output, part_index} ->
        deliver_output_to_chat(
          agent,
          chat_id,
          output,
          reply_to_id,
          base_timestamp + part_index
        )
      end)

    if Enum.all?(deliveries, &match?({:ok, _}, &1)) do
      {:ok, Enum.map(deliveries, fn {:ok, payload} -> payload end)}
    else
      {:error, :delivery_failed}
    end
  end

  @doc "Public wrapper: deliver runtime Outputs (docs/agent-platform-v1.md §3.3) via the same send path."
  def deliver_outputs(%AgentSchema{} = agent, chat_id, outputs, reply_to_id) when is_list(outputs) do
    maybe_deliver(agent, chat_id, outputs, "send", reply_to_id)
  end

  defp deliver_output_to_chat(agent, chat_id, output, reply_to_id, timestamp) do
    message_id = Ecto.UUID.generate()
    message_type = output_type(output)
    plain_text = output_text(output)
    media_url = output_media_url(output)

    agent_username =
      case agent.agent_user do
        %{username: username} when is_binary(username) -> username
        _ -> nil
      end

    metadata =
      output_metadata(output)
      |> Map.put("replyToId", reply_to_id)
      |> Map.put("isAgentMessage", true)
      |> Map.put("agentId", agent.id)
      |> Map.put("agentName", agent.display_name)
      |> Map.put("agentUserId", agent.agent_user_id)
      |> Map.put("agentUsername", agent_username)
      |> Map.put("agentHandle", if(agent_username, do: "@#{agent_username}", else: nil))

    payload =
      %{
        "id" => message_id,
        "fromId" => agent.agent_user_id,
        "chatId" => chat_id,
        "encryptedContent" => "",
        "plainContent" => plain_text,
        "plaintext" => plain_text,
        "type" => message_type,
        "timestamp" => timestamp,
        "status" => "sent",
        "isAgentMessage" => true,
        "agentName" => agent.display_name,
        "agentId" => agent.id,
        "agentUserId" => agent.agent_user_id,
        "agentUsername" => agent_username,
        "agentHandle" => if(agent_username, do: "@#{agent_username}", else: nil),
        "mediaUrl" => media_url,
        "metadata" => metadata,
        "replyToId" => reply_to_id
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    message_attrs =
      %{
        id: message_id,
        chat_id: chat_id,
        from_id: agent.agent_user_id,
        encrypted_content: AgentMessageCrypto.encrypt_for_storage(plain_text),
        type: message_type,
        media_url: media_url,
        metadata: metadata,
        reply_to_id: reply_to_id,
        timestamp: timestamp
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Chat.add_message(message_attrs, acting_user_id: agent.agent_user_id) do
      {:ok, _message} ->
        VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message", payload)

        mirrored_message = Chat.mirrored_message_payload(payload)

        Chat.get_all_participant_settings(chat_id)
        |> Enum.each(fn participant ->
          if participant.user_id != agent.agent_user_id do
            VibeWeb.Endpoint.broadcast!("user:#{participant.user_id}", "new_message", %{
              chat_id: chat_id,
              from_id: agent.agent_user_id,
              message_id: message_id,
              timestamp: timestamp,
              muted: participant.muted || false,
              message: mirrored_message
            })

            if not participant.muted do
              _ =
                Notifications.send_message_push(participant.user_id, %{
                  "chat_id" => chat_id,
                  "message_id" => message_id,
                  "from_id" => agent.agent_user_id,
                  "type" => message_type,
                  "body" => plain_text,
                  "media_url" => media_url
                })
            end
          end
        end)

        {:ok, %{messageId: message_id, type: message_type, mediaUrl: media_url}}

      error ->
        error
    end
  end

  defp build_system_prompt(agent, has_prior_messages) do
    [
      "You are #{agent.display_name}, a custom AI agent inside the Vibe app.",
      "Respond clearly and practically.",
      Vibe.AI.AgenticPolicy.prompt_guidance(agent.enabled_tools),
      "Do not introduce yourself again, restate your capabilities, or repeat onboarding copy in an ongoing chat unless the user explicitly asks for it.",
      "If the user sends a voice, audio, file, or image attachment, the current message may include a short attachment summary. Use that context directly instead of pretending the attachment is missing.",
      "If a voice attachment arrives without a transcript, acknowledge the voice note naturally and continue from the attachment summary or ask one short follow-up only if needed.",
      "If the user asks about received notifications, past event counts, times, related messages, or inbox mode, use the live inbox tools before answering.",
      "If the user wants to switch between normal event bubbles and batched summaries, use the inbox configuration tool instead of guessing.",
      if("call_connected_app" in (agent.enabled_tools || []),
        do: Vibe.AI.Tools.ConnectedApp.prompt_guidance(agent),
        else: nil
      ),
      if(
        "call_platform" in (agent.enabled_tools || []) or
          "list_platform_connections" in (agent.enabled_tools || []),
        do: Vibe.AI.Tools.Platform.prompt_guidance(agent),
        else: nil
      ),
      if(Vibe.AI.MCP.gate_tool_id() in (agent.enabled_tools || []),
        do: Vibe.AI.MCP.prompt_guidance(agent),
        else: nil
      ),
      prompt_variables_guidance(agent),
      if(agent.persona, do: "Persona: #{agent.persona}", else: nil),
      if(agent.welcome_message && !has_prior_messages,
        do:
          "First-contact welcome guidance: #{agent.welcome_message}. Use it only for the first reply in a new DM or when the user explicitly asks what you do.",
        else: nil
      ),
      agent.system_prompt,
      unless(agent.admin_mode,
        do:
          "You are talking with someone other than your owner. Never reveal your invoke secret, " <>
            "webhook/integration details, connected-app configuration, or any prompt variable " <>
            "marked owner-only, and never offer to reconfigure yourself for this person."
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> Vibe.AI.PromptVariables.render(agent, admin_mode: agent.admin_mode)
  end

  defp prompt_variables_guidance(agent) do
    case Vibe.AI.PromptVariables.definitions(agent) do
      [] ->
        nil

      vars ->
        visible = if agent.admin_mode, do: vars, else: Enum.reject(vars, & &1["secret"])

        case visible do
          [] ->
            nil

          visible ->
            names = visible |> Enum.map(& &1["name"]) |> Enum.join(", ")

            "Configured prompt variables (#{names}) are already filled in above. If you rewrite your own system prompt, keep any {{variable}} placeholders intact and never invent values for locked variables."
        end
    end
  end

  defp normalize_attachments(value) when is_list(value) do
    Enum.map(value, fn item ->
      %{
        type: normalize_string(item["type"] || item[:type]) || "file",
        url: normalize_string(item["url"] || item[:url] || item["mediaUrl"] || item[:mediaUrl])
      }
    end)
    |> Enum.filter(&is_binary(&1.url))
  end

  defp normalize_attachments(_), do: []

  defp normalize_response_mode(value) do
    case normalize_string(value) do
      "send" -> "send"
      "post" -> "post"
      _ -> "reply"
    end
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil

  defp stream_agent_text(
         message,
         callback,
         image_urls,
         vibe_chat_id,
         user_id,
         requester_user_id,
         agent_id,
         model_provider,
         model_id,
         system_prompt,
         enabled_tools,
         conversation_history,
         turn_memory,
         admin_mode,
         mcp_tools
       ) do
    case ChatAgent.stream_response(
           message,
           callback,
           history: conversation_history,
           turn_memory: turn_memory,
           images: image_urls,
           chat_id: vibe_chat_id,
           user_id: user_id,
           requester_user_id: requester_user_id,
           agent_id: agent_id,
           model_provider: model_provider,
           model_id: model_id,
           system_prompt: system_prompt,
           enabled_tools: enabled_tools,
           admin_mode: admin_mode,
           mcp_tools: mcp_tools
         ) do
      {:ok, final_text} ->
        {:ok, final_text}

      {:ok, final_text, _state} ->
        {:ok, final_text}

      other ->
        other
    end
  end

  defp mcp_tool_specs(agent) do
    if Vibe.AI.MCP.gate_tool_id() in (agent.enabled_tools || []) do
      Vibe.AI.MCP.tool_specs(agent)
    else
      []
    end
  rescue
    error ->
      Logger.warning("[StandaloneAgent] MCP discovery failed: #{inspect(error)}")
      []
  end

  defp build_attachment_context(attachments) when is_list(attachments) do
    lines =
      Enum.flat_map(attachments, fn attachment ->
        case {normalize_string(attachment.type), normalize_string(attachment.url)} do
          {"image", url} when is_binary(url) -> ["- image: #{url}"]
          {"voice", url} when is_binary(url) -> ["- voice: #{url}"]
          {"audio", url} when is_binary(url) -> ["- audio: #{url}"]
          {"music", url} when is_binary(url) -> ["- audio: #{url}"]
          {"file", url} when is_binary(url) -> ["- file: #{url}"]
          {"document", url} when is_binary(url) -> ["- document: #{url}"]
          {type, url} when is_binary(type) and is_binary(url) -> ["- #{type}: #{url}"]
          _ -> []
        end
      end)
      |> Enum.uniq()

    if lines == [], do: "", else: "Attached context:\n" <> Enum.join(lines, "\n")
  end

  defp build_attachment_context(_), do: ""

  defp append_attachment_context(message, attachment_context) do
    base =
      message
      |> to_string()
      |> String.trim()

    if attachment_context == "" do
      base
    else
      [base, attachment_context]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
    end
  end

  defp finalize_outputs(agent, final_text, tool_outputs, text_metadata, requested_output_mode) do
    rich_outputs =
      tool_outputs
      |> List.wrap()
      |> Enum.reject(&is_nil/1)

    normalized_text =
      final_text
      |> to_string()
      |> String.trim()
      |> case do
        "" -> question_fallback_text(rich_outputs) || ""
        text -> text
      end

    text_outputs = maybe_append_text_output([], normalized_text, text_metadata)

    voice_outputs =
      if requested_output_mode == "voice" and normalized_text != "" and
           "voice" in (agent.output_modes || []) do
        case TTS.synthesize(normalized_text, voice: agent.voice_profile || "alloy") do
          {:ok, voice} ->
            [
              %{
                type: "voice",
                text: normalized_text,
                mediaUrl: voice.media_url,
                metadata: %{"duration" => voice.duration, "mimeType" => "audio/mpeg"}
              }
            ]

          {:error, reason} ->
            Logger.warning("[StandaloneAgent] TTS failed: #{inspect(reason)}")
            []
        end
      else
        []
      end

    text_outputs ++ rich_outputs ++ voice_outputs
  end

  defp maybe_append_text_output(outputs, "", _metadata), do: outputs
  defp maybe_append_text_output(outputs, nil, _metadata), do: outputs

  defp maybe_append_text_output(outputs, text, metadata) do
    outputs ++ [%{type: "text", text: text, metadata: metadata || %{}}]
  end

  @doc false
  def tool_outputs_from_result(tool_name, result)
      when tool_name in ["create_document", "edit_rows", "delete_rows", "export_rows"] and
             is_map(result) do
    ok? = Map.get(result, :ok) || Map.get(result, "ok")

    file_url =
      Map.get(result, :file_url) ||
        Map.get(result, "file_url") ||
        Map.get(result, :download_path) ||
        Map.get(result, "download_path")

    with true <- ok? == true,
         url when is_binary(url) <- normalize_string(file_url) do
      mime_type = detect_mime_type(url)
      metadata = %{"fileName" => file_name_from_url(url), "mimeType" => mime_type}

      [
        %{
          type: if(image_output?(url, mime_type), do: "image", else: "file"),
          mediaUrl: url,
          metadata: metadata
        }
      ]
    else
      _ -> []
    end
  end

  def tool_outputs_from_result("mcp__" <> _rest, result) when is_map(result) do
    Vibe.AI.MCP.outputs_from_result(result)
  end

  def tool_outputs_from_result("search_music", result) when is_map(result) do
    source = map_value(result, :source) || "music"

    result
    |> map_value(:tracks)
    |> List.wrap()
    |> Enum.map(&music_output(&1, source))
    |> Enum.reject(&is_nil/1)
  end

  def tool_outputs_from_result("ask_user", result) when is_map(result) do
    status = map_value(result, :status)
    questions = map_value(result, :questions)
    request_id = map_value(result, :requestId) || map_value(result, :request_id)
    fallback = map_value(result, :fallbackText) || map_value(result, :fallback_text)

    if status == "waiting_for_user" and is_binary(request_id) and is_list(questions) do
      [
        %{
          type: "question",
          text: normalize_string(fallback) || "Your input is needed to continue.",
          requestId: request_id,
          status: status,
          questions: questions,
          metadata: %{
            "requestId" => request_id,
            "status" => status,
            "questions" => questions
          }
        }
      ]
    else
      []
    end
  end

  def tool_outputs_from_result(_tool_name, _result), do: []

  @doc false
  def finalize_batch(outputs, opts \\ []) do
    agent_turn_id = Keyword.get(opts, :agent_turn_id) || Ecto.UUID.generate()
    agent_batch_id = Keyword.get(opts, :agent_batch_id) || Ecto.UUID.generate()
    base_timestamp = Keyword.get(opts, :base_timestamp) || :os.system_time(:millisecond)
    outputs = List.wrap(outputs)
    part_count = length(outputs)

    outputs
    |> Enum.with_index()
    |> Enum.map(fn {output, part_index} ->
      kind = output_type(output)

      batch_metadata = %{
        "agentTurnId" => agent_turn_id,
        "agentBatchId" => agent_batch_id,
        "agentPartId" => Ecto.UUID.generate(),
        "agentPartIndex" => part_index,
        "agentPartCount" => part_count,
        "agentPartKind" => kind,
        "agentFinalized" => true
      }

      output
      |> Map.drop([:metadata, "metadata", :timestamp, "timestamp"])
      |> Map.put(:metadata, Map.merge(output_metadata(output), batch_metadata))
      |> Map.put(:timestamp, base_timestamp + part_index)
    end)
  end

  @doc false
  def finalized_rich_outputs(tool_results, final_text, opts \\ []) do
    rich_outputs =
      tool_results
      |> List.wrap()
      |> select_music_tool_results()
      |> Enum.flat_map(fn item ->
        tool = map_value(item, :tool)
        result = map_value(item, :result)
        tool_outputs_from_result(tool, result)
      end)
      |> dedupe_media_outputs()

    if rich_outputs == [] do
      []
    else
      text_output = %{type: "text", text: normalize_string(final_text) || ""}

      [text_output | rich_outputs]
      |> finalize_batch(opts)
      |> Enum.reject(&(output_type(&1) == "text"))
    end
  end

  @doc false
  def select_music_tool_results(tool_results) do
    music_indices =
      tool_results
      |> Enum.with_index()
      |> Enum.filter(fn {item, _index} ->
        map_value(item, :tool) == "search_music" and
          not error_result?(map_value(item, :result)) and
          music_tracks?(map_value(item, :result))
      end)
      |> Enum.map(fn {_item, index} -> index end)

    case List.last(music_indices) do
      nil ->
        tool_results

      keep_index ->
        drop = MapSet.new(music_indices -- [keep_index])

        tool_results
        |> Enum.with_index()
        |> Enum.reject(fn {_item, index} -> MapSet.member?(drop, index) end)
        |> Enum.map(fn {item, _index} -> item end)
    end
  end

  defp music_tracks?(result) when is_map(result) do
    (map_value(result, :tracks) || []) |> List.wrap() |> Enum.any?()
  end

  defp music_tracks?(_result), do: false

  defp error_result?(result) when is_map(result) do
    case map_value(result, :error) do
      value when is_binary(value) -> true
      %{} -> true
      _ -> map_value(result, :ok) == false
    end
  end

  defp error_result?(_result), do: false

  defp dedupe_media_outputs(outputs) do
    {deduped, _seen} =
      Enum.reduce(outputs, {[], MapSet.new()}, fn output, {kept, seen} ->
        key = media_dedupe_key(output)

        cond do
          is_nil(key) -> {kept ++ [output], seen}
          MapSet.member?(seen, key) -> {kept, seen}
          true -> {kept ++ [output], MapSet.put(seen, key)}
        end
      end)

    deduped
  end

  defp media_dedupe_key(output) when is_map(output) do
    metadata = map_value(output, :metadata) || %{}

    case map_value(metadata, :videoId) || map_value(metadata, :trackId) ||
           map_value(output, :mediaUrl) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp media_dedupe_key(_output), do: nil

  @doc false
  def final_text_with_tool_fallback(final_text, tool_results) do
    case normalize_string(final_text) do
      text when is_binary(text) ->
        text

      nil ->
        tool_results
        |> List.wrap()
        |> Enum.flat_map(fn item ->
          tool_outputs_from_result(map_value(item, :tool), map_value(item, :result))
        end)
        |> question_fallback_text()
        |> case do
          nil -> ""
          text -> text
        end
    end
  end

  defp question_fallback_text(outputs) do
    outputs
    |> Enum.find(&(output_type(&1) == "question"))
    |> case do
      nil -> nil
      output -> normalize_string(output_text(output))
    end
  end

  defp response_status(outputs) do
    if Enum.any?(outputs, fn output ->
         map_value(output, :status) == "waiting_for_user" or
           map_value(output_metadata(output), :status) == "waiting_for_user"
       end) do
      "waiting_for_user"
    else
      "completed"
    end
  end

  defp music_output(track, source) when is_map(track) do
    video_id = map_value(track, :video_id) || map_value(track, :videoId)
    preview_url = map_value(track, :preview_url) || map_value(track, :previewUrl)
    track_source = map_value(track, :source) || source
    links = map_value(track, :links) || %{}

    media_url =
      cond do
        is_binary(normalize_string(video_id)) -> public_music_stream_url(video_id)
        is_binary(normalize_string(preview_url)) -> normalize_string(preview_url)
        true -> nil
      end

    if is_binary(media_url) do
      duration = map_value(track, :duration)
      track_id = map_value(track, :track_id) || map_value(track, :trackId) || video_id

      duration_secs =
        case map_value(track, :duration_seconds) || duration_seconds(duration) do
          n when is_float(n) -> round(n)
          n when is_integer(n) -> n
          _ -> nil
        end

      metadata = %{
        "trackId" => track_id,
        "videoId" => video_id,
        "title" => map_value(track, :title),
        "artist" => map_value(track, :artist),
        "album" => map_value(track, :album),
        "duration" => duration,
        "durationSeconds" => duration_secs,
        "cover" => map_value(track, :cover),
        "source" => track_source,
        "links" => links,
        "previewUrl" => media_url,
        "streamUrl" => media_url,
        "mediaUrl" => media_url
      }

      %{
        type: "music",
        text: map_value(track, :title) || "Music",
        mediaUrl: media_url,
        metadata: metadata
      }
    end
  end

  defp music_output(_, _), do: nil

  defp duration_seconds(value) when is_integer(value), do: value
  defp duration_seconds(value) when is_float(value), do: round(value)

  defp duration_seconds(value) when is_binary(value) do
    case String.split(String.trim(value), ":") do
      [minutes, seconds] ->
        with {minutes, ""} <- Integer.parse(minutes),
             {seconds, ""} <- Integer.parse(seconds) do
          minutes * 60 + seconds
        else
          _ -> parse_duration_integer(value)
        end

      _ ->
        parse_duration_integer(value)
    end
  end

  defp duration_seconds(_), do: nil

  defp parse_duration_integer(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} -> seconds
      _ -> nil
    end
  end

  defp public_music_stream_url(video_id) do
    path = "/api/music/stream/#{URI.encode_www_form(to_string(video_id))}"
    String.trim_trailing(public_api_base_url(), "/") <> path
  end

  defp public_api_base_url do
    cond do
      base = present_env("PUBLIC_BASE_URL") ->
        normalize_api_base(base)

      base = present_env("API_BASE_URL") ->
        normalize_api_base(base)

      base = present_env("VIBE_PUBLIC_BASE_URL") ->
        normalize_api_base(base)

      host = present_env("PHX_HOST") ->
        if String.starts_with?(host, "http"),
          do: String.trim_trailing(host, "/"),
          else: "https://" <> host

      true ->
        "https://api.vibegram.io"
    end
  end

  defp present_env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp normalize_api_base(base) do
    base
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_, _), do: nil

  defp text_metadata_from_result("query_event_inbox", result) when is_map(result) do
    related_message_ids =
      Map.get(result, "related_message_ids") ||
        Map.get(result, :related_message_ids) ||
        []

    if is_list(related_message_ids) and related_message_ids != [] do
      %{
        "relatedMessageIds" => Enum.filter(related_message_ids, &is_binary/1),
        "relatedMessagesTitle" =>
          Map.get(result, "related_title") || Map.get(result, :related_title) ||
            "Related messages",
        "relatedMessagesSubtitle" =>
          Map.get(result, "related_subtitle") || Map.get(result, :related_subtitle) ||
            "Tap to review"
      }
    else
      %{}
    end
  end

  defp text_metadata_from_result(_tool_name, _result), do: %{}

  defp merge_outputs(existing, new_outputs) do
    List.wrap(existing) ++ List.wrap(new_outputs)
  end

  defp recent_chat_history(chat_id, requester_user_id, agent_user_id)
       when is_binary(chat_id) and is_binary(requester_user_id) and is_binary(agent_user_id) do
    chat_id
    |> Chat.get_messages_for_user(requester_user_id)
    |> Enum.map(&history_entry_from_message(&1, agent_user_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.take(-@conversation_history_limit)
  end

  defp recent_chat_history(_, _, _), do: []

  @runtime_history_limit 30

  @doc "Chat history as RunRequest.context.history entries ({role,authorName,text,ts}), capped at 30."
  def history_for_runtime(chat_id, requester_user_id, agent_user_id)
      when is_binary(chat_id) and is_binary(requester_user_id) and is_binary(agent_user_id) do
    chat_id
    |> Chat.get_messages_for_user(requester_user_id)
    |> Enum.map(&runtime_history_entry(&1, agent_user_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.take(-@runtime_history_limit)
  end

  def history_for_runtime(_, _, _), do: []

  defp runtime_history_entry(message, agent_user_id) when is_map(message) do
    from_id = Map.get(message, :from_id) || Map.get(message, "from_id")
    agent_turn? = from_id == agent_user_id

    case message_text_for_history(message, agent_turn?) do
      nil ->
        nil

      text ->
        %{
          role: if(agent_turn?, do: "assistant", else: "user"),
          authorName: runtime_history_author_name(message, agent_turn?),
          text: text,
          ts: Map.get(message, :timestamp) || Map.get(message, "timestamp")
        }
    end
  end

  defp runtime_history_entry(_message, _agent_user_id), do: nil

  defp runtime_history_author_name(message, true) do
    metadata = Map.get(message, :metadata) || Map.get(message, "metadata") || %{}
    map_value(metadata, :agentName) || map_value(metadata, :agent_name)
  end

  defp runtime_history_author_name(_message, false), do: nil

  defp turn_memory_from_chat(chat_id, requester_user_id, agent_user_id)
       when is_binary(chat_id) and is_binary(requester_user_id) and is_binary(agent_user_id) do
    chat_id
    |> Chat.get_messages_for_user(requester_user_id)
    |> Enum.filter(fn message ->
      (Map.get(message, :from_id) || Map.get(message, "from_id")) == agent_user_id
    end)
    |> Enum.map(&memory_entry_from_message/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(-6)
  end

  defp turn_memory_from_chat(_, _, _), do: []

  defp memory_entry_from_message(message) when is_map(message) do
    metadata =
      case Map.get(message, :metadata) || Map.get(message, "metadata") do
        value when is_map(value) -> value
        _ -> %{}
      end

    type = normalize_string(Map.get(message, :type) || Map.get(message, "type"))
    title = normalize_string(map_value(metadata, :title))
    track_id = normalize_string(map_value(metadata, :videoId) || map_value(metadata, :trackId))
    file_name = normalize_string(map_value(metadata, :fileName))

    cond do
      type == "music" and is_binary(title) ->
        id_part = if is_binary(track_id), do: " [#{track_id}]", else: ""
        ~s(search_music → sent "#{String.slice(title, 0, 70)}"#{id_part})

      is_binary(file_name) ->
        ~s(sent file "#{String.slice(file_name, 0, 70)}")

      true ->
        nil
    end
  end

  defp memory_entry_from_message(_message), do: nil

  defp chat_has_prior_messages?(chat_id, requester_user_id)
       when is_binary(chat_id) and is_binary(requester_user_id) do
    case Chat.get_messages_for_user(chat_id, requester_user_id) do
      [] -> false
      [_ | _] -> true
      _ -> false
    end
  end

  defp chat_has_prior_messages?(_, _), do: false

  defp history_entry_from_message(message, agent_user_id) when is_map(message) do
    from_id = Map.get(message, :from_id) || Map.get(message, "from_id")

    cond do
      from_id == agent_user_id ->
        case message_text_for_history(message, true) do
          nil -> nil
          content -> %{role: "assistant", content: content}
        end

      true ->
        case message_text_for_history(message, false) do
          nil -> nil
          content -> %{role: "user", content: content}
        end
    end
  end

  defp history_entry_from_message(_, _), do: nil

  defp message_text_for_history(message, agent_message?) do
    metadata =
      case Map.get(message, :metadata) || Map.get(message, "metadata") do
        value when is_map(value) -> value
        _ -> %{}
      end

    value =
      cond do
        agent_message? ->
          Map.get(message, :plaintext) ||
            Map.get(message, "plaintext") ||
            Map.get(message, :plain_content) ||
            Map.get(message, "plain_content") ||
            Map.get(message, :plainContent) ||
            Map.get(message, "plainContent")

        true ->
          Map.get(metadata, "agentInputCiphertext") ||
            Map.get(metadata, :agentInputCiphertext) ||
            Map.get(metadata, "agent_input_ciphertext") ||
            Map.get(metadata, :agent_input_ciphertext)
      end

    value
    |> maybe_decrypt_history_text(agent_message?)
    |> normalize_string()
  end

  defp maybe_decrypt_history_text(value, true), do: value

  defp maybe_decrypt_history_text(value, false) when is_binary(value) do
    AgentMessageCrypto.decrypt_from_storage(value)
  end

  defp maybe_decrypt_history_text(value, _), do: value

  defp output_type(output) when is_map(output) do
    normalize_string(Map.get(output, :type) || Map.get(output, "type")) || "text"
  end

  defp output_type(_), do: "text"

  defp output_text(output) when is_map(output) do
    normalize_string(Map.get(output, :text) || Map.get(output, "text")) || ""
  end

  defp output_text(_), do: ""

  defp output_media_url(output) when is_map(output) do
    normalize_string(
      Map.get(output, :mediaUrl) ||
        Map.get(output, "mediaUrl") ||
        Map.get(output, :media_url) ||
        Map.get(output, "media_url")
    )
  end

  defp output_media_url(_), do: nil

  defp output_metadata(output) when is_map(output) do
    case Map.get(output, :metadata) || Map.get(output, "metadata") do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp output_metadata(_), do: %{}

  defp provider_content_from_params(%{"providerContent" => content}) when is_map(content),
    do: content

  defp provider_content_from_params(_), do: nil

  defp put_provider_content_on_outputs(outputs, nil), do: outputs

  defp put_provider_content_on_outputs(outputs, content) when is_map(content) do
    Enum.map(List.wrap(outputs), fn
      output when is_map(output) ->
        meta = output_metadata(output) |> Map.put("content", content)

        output
        |> Map.drop([:metadata, "metadata"])
        |> Map.put(:metadata, meta)

      other ->
        other
    end)
  end

  defp image_output?(url, mime_type) do
    mime_type in ["image/png", "image/jpeg", "image/webp", "image/gif"] or
      String.match?(String.downcase(url), ~r/\.(png|jpg|jpeg|webp|gif)(\?|$)/)
  end

  defp detect_mime_type(url) do
    lowered = String.downcase(url)

    cond do
      String.match?(lowered, ~r/\.png(\?|$)/) ->
        "image/png"

      String.match?(lowered, ~r/\.jpe?g(\?|$)/) ->
        "image/jpeg"

      String.match?(lowered, ~r/\.webp(\?|$)/) ->
        "image/webp"

      String.match?(lowered, ~r/\.gif(\?|$)/) ->
        "image/gif"

      String.match?(lowered, ~r/\.pdf(\?|$)/) ->
        "application/pdf"

      String.match?(lowered, ~r/\.xlsx?(\?|$)/) ->
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

      String.match?(lowered, ~r/\.csv(\?|$)/) ->
        "text/csv"

      true ->
        "application/octet-stream"
    end
  end

  defp file_name_from_url(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil ->
        "document"

      path ->
        case Path.basename(path) do
          "" -> "document"
          name -> name
        end
    end
  rescue
    _ -> "document"
  end
end
