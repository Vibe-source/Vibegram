defmodule Vibe.AI.AgentBuilder do
  @moduledoc false

  alias Vibe.Agents
  alias Vibe.AgentConversation
  alias Vibe.AI.AgentRuntime
  alias Vibe.AI.AgentBuilderSetup
  alias Vibe.AI.GroupAgent
  alias Vibe.Chat
  alias Vibe.AI.ToolRegistry

  @builder_deep_link "vibe://agent?mode=builder"
  @claude_model "claude-haiku-4-5-20251001"
  @max_tool_depth 6

  @builder_tools [
    %{
      name: "get_builder_context",
      description:
        "Read the owner's current builder state, agent list, quota, selected agent, prompt status, and integration data. Use this before answering setup or integration questions.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{
            type: "string",
            description:
              "Optional agent id or @username to inspect instead of the currently selected draft."
          }
        }
      }
    },
    %{
      name: "create_agent",
      description:
        "Create a new standalone Vibe agent draft. Use when the owner asks to create a new agent in plain language or with slash shorthand like /newagent.",
      input_schema: %{
        type: "object",
        properties: %{
          display_name: %{
            type: "string",
            description: "Human-readable display name for the draft."
          },
          username: %{type: "string", description: "Optional public username without @."},
          description: %{
            type: "string",
            description:
              "Optional natural-language description of how the agent should behave. If provided, this tool should generate a system prompt for the new draft."
          },
          system_prompt: %{
            type: "string",
            description: "Optional final system prompt to save immediately."
          },
          persona: %{type: "string", description: "Optional persona or character summary."},
          model_provider: %{
            type: "string",
            enum: ["anthropic", "openai"],
            description: "Optional runtime provider. The server model registry is authoritative."
          },
          model_id: %{
            type: "string",
            description: "Optional allowlisted model id for the selected provider."
          },
          callback_url: %{
            type: "string",
            description:
              "Optional callback URL. Use 'off' only when updating an existing agent, not during creation."
          },
          enabled_tools: %{
            type: "array",
            items: %{type: "string"},
            description: "Optional tool ids to enable."
          },
          output_modes: %{
            type: "array",
            items: %{type: "string"},
            description: "Optional output modes from text, media, voice."
          },
          voice_profile: %{
            type: "string",
            description: "Optional voice profile, for example alloy."
          }
        }
      }
    },
    %{
      name: "select_agent",
      description:
        "Select an existing owned agent by id or @username so later updates, publishing, and integration answers use that agent.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{type: "string", description: "Agent id or @username to select."}
        },
        required: ["identifier"]
      }
    },
    %{
      name: "update_agent",
      description:
        "Update the selected agent or a specific agent. Use this for name, username, prompt, persona, webhook, tool list, voice mode, or general reconfiguration. Slash commands are only shorthand; still use this tool.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{
            type: "string",
            description: "Optional target agent id or @username. Defaults to the selected draft."
          },
          display_name: %{type: "string", description: "Updated display name."},
          username: %{type: "string", description: "Updated public username without @."},
          description: %{
            type: "string",
            description:
              "Optional natural-language behavior description. If present, this tool should generate and save an updated system prompt."
          },
          system_prompt: %{type: "string", description: "Updated final system prompt."},
          persona: %{type: "string", description: "Updated persona summary."},
          model_provider: %{
            type: "string",
            enum: ["anthropic", "openai"],
            description: "Updated runtime provider."
          },
          model_id: %{
            type: "string",
            description: "Updated allowlisted model id."
          },
          callback_url: %{
            type: "string",
            description: "Updated callback URL. Use 'off' to disable callbacks."
          },
          enabled_tools: %{
            type: "array",
            items: %{type: "string"},
            description: "Tool ids to enable."
          },
          output_modes: %{
            type: "array",
            items: %{type: "string"},
            description: "Output modes from text, media, voice."
          },
          voice_profile: %{type: "string", description: "Voice profile like alloy."},
          welcome_message: %{
            type: "string",
            description: "Optional welcome message for the agent."
          }
        }
      }
    },
    %{
      name: "generate_system_prompt",
      description:
        "Generate a production-quality system prompt from a plain-language description without saving it yet. Use this when the owner asks you to draft or improve the prompt.",
      input_schema: %{
        type: "object",
        properties: %{
          description: %{
            type: "string",
            description: "What the agent should do and how it should behave."
          },
          enabled_tools: %{
            type: "array",
            items: %{type: "string"},
            description: "Optional tool ids to optimize the prompt for."
          }
        },
        required: ["description"]
      }
    },
    %{
      name: "publish_agent",
      description: "Publish the selected agent or a specific agent when it is ready for use.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{
            type: "string",
            description: "Optional agent id or @username. Defaults to the selected draft."
          }
        }
      }
    },
    %{
      name: "set_agent_status",
      description:
        "Set agent status to draft, published, or disabled. Use this for disable/enable requests.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{
            type: "string",
            description: "Optional agent id or @username. Defaults to the selected draft."
          },
          status: %{
            type: "string",
            enum: ["draft", "published", "disabled"],
            description: "New agent status."
          }
        },
        required: ["status"]
      }
    },
    %{
      name: "archive_agent",
      description:
        "Archive (remove) the selected agent or a specific agent owned by the user. Use this when the owner asks to delete, remove, archive, or clean up an agent.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{
            type: "string",
            description: "Optional agent id or @username. Defaults to the selected draft."
          }
        }
      }
    },
    %{
      name: "rotate_secret",
      description:
        "Rotate the invoke secret for the selected agent or a specific agent. Use this when the owner asks for the current secret or wants a new one.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{
            type: "string",
            description: "Optional agent id or @username. Defaults to the selected draft."
          }
        }
      }
    },
    %{
      name: "get_integration_details",
      description:
        "Read the exact integration details for an agent, including agent id, user id, username, invoke URL, responseMode guidance, callback signing, and attached vibeChatId values.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{
            type: "string",
            description: "Optional agent id or @username. Defaults to the selected draft."
          }
        }
      }
    },
    %{
      name: "ensure_destination_chat",
      description:
        "Create or reuse a real Vibe DM between the owner and the selected agent, return the attached chat id, and set it as the default destination when helpful. Use this when the owner asks for the chat id or wants the easiest event destination.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{
            type: "string",
            description: "Optional agent id or @username. Defaults to the selected draft."
          },
          set_as_default: %{
            type: "boolean",
            description:
              "Optional. When true, save this chat as the agent's default destination. When omitted, it is set automatically only if the agent has no default destination yet."
          }
        }
      }
    },
    %{
      name: "validate_destination_chat",
      description:
        "Look up the current owner-visible destination chat for the selected agent, compare it with a provided chat id, and repair stale or missing default destination settings when needed. Use this when the owner asks whether a chat id is correct, asks again for the current chat id, says the previous id may be wrong, or asks for the current destination after setup.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{
            type: "string",
            description: "Optional agent id or @username. Defaults to the selected draft."
          },
          chat_id: %{
            type: "string",
            description:
              "Optional chat id to verify against the agent's current live destination state."
          },
          repair_default: %{
            type: "boolean",
            description:
              "Optional. Defaults to true. When true, repair stale or missing default destination settings before returning the current chat id."
          }
        }
      }
    },
    %{
      name: "check_agent_username",
      description:
        "Check whether a public @username is free, and get clean alternatives when it is taken. Call this before create_agent (and before renaming a draft's username): the username becomes the agent's permanent public link, and taken names are refused rather than auto-suffixed.",
      input_schema: %{
        type: "object",
        properties: %{
          username: %{type: "string", description: "Candidate username without @."},
          display_name: %{
            type: "string",
            description: "Optional name to derive suggestions from when the candidate is taken."
          }
        },
        required: ["username"]
      }
    }
  ]

  def handle_message(user_id, message, opts \\ []) do
    active_agent_id = Keyword.get(opts, :active_agent_id)
    ui_response = Keyword.get(opts, :ui_response)

    process_message(user_id, message, active_agent_id, ui_response, nil, subagent_mode: false)
  end

  def stream_message(user_id, message, callback, opts \\ []) when is_function(callback, 1) do
    active_agent_id = Keyword.get(opts, :active_agent_id)
    ui_response = Keyword.get(opts, :ui_response)

    process_message(user_id, message, active_agent_id, ui_response, callback,
      subagent_mode: false
    )
  end

  def delegate_task(user_id, message, opts \\ []) do
    active_agent_id = Keyword.get(opts, :active_agent_id)
    ui_response = Keyword.get(opts, :ui_response)
    callback = Keyword.get(opts, :callback)

    trimmed_message = normalize_optional_string(message)

    with true <- is_binary(trimmed_message) or is_map(ui_response),
         {:ok, result} <-
           delegate_builder_request(
             user_id,
             trimmed_message,
             active_agent_id,
             ui_response,
             callback
           ) do
      selected_agent_id = result[:active_agent_id] || result[:activeAgentId]
      latest_secret = result[:latest_secret] || result[:latestSecret]
      selected_agent = resolve_owned_agent(user_id, nil, selected_agent_id)
      selected_agent_payload = if selected_agent, do: Agents.agent_payload(selected_agent)

      reply =
        normalize_optional_string(result[:reply] || result["reply"]) ||
          fallback_reply(selected_agent)

      {:ok,
       %{
         reply: reply,
         active_agent_id: selected_agent_id,
         latest_secret: latest_secret,
         metadata:
           %{}
           |> maybe_put("selected_agent_id", selected_agent_id)
           |> maybe_put(
             "selected_agent_username",
             selected_agent_payload &&
               (Map.get(selected_agent_payload, :username) ||
                  Map.get(selected_agent_payload, "username"))
           )
       }}
    else
      false -> {:error, "message is required"}
      error -> error
    end
  end

  defp delegate_builder_request(user_id, trimmed_message, active_agent_id, ui_response, callback) do
    cond do
      is_map(ui_response) ->
        process_message(
          user_id,
          trimmed_message,
          active_agent_id,
          ui_response,
          callback,
          subagent_mode: true
        )

      is_binary(trimmed_message) ->
        run_builder_agent(user_id, [], trimmed_message, active_agent_id, callback, true)

      true ->
        {:error, "message is required"}
    end
  end

  defp process_message(user_id, message, active_agent_id, ui_response, callback, opts \\ []) do
    subagent_mode = Keyword.get(opts, :subagent_mode, false)

    with {:ok, session} <- Agents.get_or_create_builder_session(user_id) do
      input = %{message: normalize_optional_string(message), ui_response: ui_response}

      cond do
        AgentBuilderSetup.handles?(input, session.metadata || %{}, active_agent_id) ->
          AgentBuilderSetup.handle(user_id, session, input, active_agent_id, callback)

        is_binary(input.message) ->
          history = session.messages || []

          _ =
            AgentConversation.add_message(session.id, %{
              "role" => "user",
              "content" => input.message
            })

          with {:ok, result} <-
                 run_builder_agent(
                   user_id,
                   history,
                   input.message,
                   active_agent_id,
                   callback,
                   subagent_mode
                 ) do
            persist_builder_result(session, user_id, result)
          end

        true ->
          {:error, "message is required"}
      end
    end
  end

  def session_payload(user_id) do
    with {:ok, session} <- Agents.get_or_create_builder_session(user_id) do
      active_agent_id = session.metadata && session.metadata["active_agent_id"]

      active_agent =
        if is_binary(active_agent_id), do: Agents.get_agent(active_agent_id, user_id), else: nil

      {:ok,
       %{
         conversationId: session.id,
         activeAgentId: active_agent_id,
         messages: session.messages || [],
         draftPatch:
           if(active_agent,
             do: Agents.agent_payload(active_agent),
             else: normalize_map(session.metadata && session.metadata["draft_state"])
           ),
         agent: if(active_agent, do: Agents.agent_payload(active_agent), else: nil),
         latestSecret: session.metadata && session.metadata["latest_secret"],
         suggestions: default_suggestions(active_agent)
       }
       |> Map.merge(AgentBuilderSetup.session_fields(session.metadata || %{}))}
    end
  end

  defp persist_builder_result(session, user_id, result) do
    reply = result.reply
    next_active_agent_id = result.active_agent_id
    latest_secret = result.latest_secret

    _ =
      AgentConversation.add_message(session.id, %{
        "role" => "assistant",
        "content" => reply
      })

    selected_agent =
      if is_binary(next_active_agent_id) do
        Agents.get_agent(next_active_agent_id, user_id)
      end

    payload = if selected_agent, do: Agents.agent_payload(selected_agent), else: %{}

    metadata =
      (session.metadata || %{})
      |> Map.put("kind", Agents.builder_kind())
      |> Map.put("active_agent_id", next_active_agent_id)
      |> Map.put("draft_state", payload)
      |> Map.put("latest_secret", latest_secret)

    {:ok, updated_session} = Agents.update_builder_session(session, %{metadata: metadata})

    {:ok,
     %{
       conversationId: updated_session.id,
       activeAgentId: next_active_agent_id,
       reply: reply,
       suggestions: default_suggestions(selected_agent),
       draftPatch: payload,
       agent: if(selected_agent, do: payload, else: nil),
       latestSecret: latest_secret
     }
     |> Map.merge(AgentBuilderSetup.session_fields(updated_session.metadata || %{}))}
  end

  defp run_builder_agent(user_id, history, message, active_agent_id, callback, subagent_mode) do
    messages = build_builder_messages(history, message)

    state = %{
      user_id: user_id,
      active_agent_id: active_agent_id,
      latest_secret: nil,
      subagent_mode: subagent_mode
    }

    with {:ok, raw_reply, final_state} <-
           AgentRuntime.run(messages, builder_runtime_config(state, callback)) do
      selected_agent = resolve_owned_agent(user_id, nil, final_state.active_agent_id)
      reply = normalize_optional_string(raw_reply) || fallback_reply(selected_agent)

      {:ok,
       %{
         reply: reply,
         active_agent_id: final_state.active_agent_id,
         latest_secret: final_state.latest_secret
       }}
    end
  end

  defp execute_builder_tools(tool_calls, state, callback) do
    tool_calls
    |> Enum.reduce({[], state}, fn tool, {results, acc_state} ->
      tool_name = tool["name"]
      tool_input = tool["input"] || %{}

      if is_function(callback, 1) do
        callback.(%{
          type: :progress,
          label: builder_tool_progress_label(tool_name, tool_input),
          tool: tool_name,
          tool_call_id: tool["id"],
          status: "running"
        })
      end

      {result, next_state} = execute_builder_tool(tool_name, tool_input, acc_state)
      emit_builder_ui(callback, result)
      safe_result = builder_tool_model_result(result)

      if is_function(callback, 1) do
        callback.(%{
          type: :tool_result,
          tool: tool_name,
          tool_call_id: tool["id"],
          result: safe_result,
          status: "complete"
        })
      end

      tool_result = %{
        type: "tool_result",
        tool_use_id: tool["id"],
        content: Jason.encode!(safe_result)
      }

      {results ++ [tool_result], next_state}
    end)
  end

  defp builder_runtime_config(state, callback) do
    %AgentRuntime.Config{
      model: @claude_model,
      max_tokens: if(Map.get(state, :subagent_mode), do: 900, else: 1600),
      max_depth: if(Map.get(state, :subagent_mode), do: 3, else: @max_tool_depth),
      system_prompt: &builder_system_prompt/1,
      tools: @builder_tools,
      state: state,
      callback: callback,
      stream_text?: true,
      execute_tools: &execute_builder_tools/3,
      missing_api_key_error:
        "Builder AI is unavailable because ANTHROPIC_API_KEY is not configured.",
      depth_error: "Builder AI reached the maximum tool depth.",
      request_label: "AgentBuilder"
    }
  end

  defp execute_builder_tool("get_builder_context", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))
    agent = resolve_owned_agent(user_id, identifier, state.active_agent_id)

    agents = Agents.list_agents(user_id)

    {builder_context_payload(user_id, agent, state.latest_secret)
     |> Map.put("_ui_group_id", "builder:agents:list")
     |> Map.put(
       "_ui_cards",
       build_agent_cards_payloads(agents, agent && agent.id, state.latest_secret)
     ), state}
  end

  defp execute_builder_tool("create_agent", input, state) do
    user_id = state.user_id

    attrs =
      input
      |> build_create_attrs()
      |> maybe_apply_generated_prompt(Map.get(input, "description"))

    case Agents.create_agent(user_id, attrs) do
      {:ok, agent, secret} ->
        username = agent.agent_user && agent.agent_user.username

        result = %{
          "ok" => true,
          "message" => "Agent draft created.",
          "agent" => builder_agent_context(agent, secret),
          "public_link" => Vibe.Links.agent_url(username),
          "_ui_group_id" => "builder:agent:#{agent.id}",
          "_ui_cards" => [agent_card_payload(agent, secret, "config")]
        }

        {result, %{state | active_agent_id: agent.id, latest_secret: secret}}

      {:error, reason} when reason in [:username_taken, :reserved_username, :invalid_username] ->
        {%{
           "ok" => false,
           "error" => format_reason(reason),
           "suggestions" =>
             Agents.suggest_usernames(
               Map.get(input, "display_name") || Map.get(input, "username") || "agent"
             ),
           "next_step" =>
             "Ask the owner which @username they want, confirm it with check_agent_username, " <>
               "then call create_agent again. Never add random characters to force it through."
         }, state}

      {:error, reason} ->
        {%{"ok" => false, "error" => format_reason(reason)}, state}
    end
  end

  defp execute_builder_tool("check_agent_username", input, state) do
    candidate =
      (Map.get(input, "username") || "")
      |> to_string()
      |> String.trim()
      |> String.trim_leading("@")

    display_name = Map.get(input, "display_name") || candidate

    result =
      case Agents.username_availability(candidate, nil) do
        {:ok, normalized} ->
          %{
            "ok" => true,
            "available" => true,
            "username" => normalized,
            "public_link" => Vibe.Links.agent_url(normalized)
          }

        {:error, reason} ->
          %{
            "ok" => true,
            "available" => false,
            "username" => candidate,
            "reason" => to_string(reason),
            "error" => format_reason(reason),
            "suggestions" => Agents.suggest_usernames(display_name)
          }
      end

    {result, state}
  end

  defp execute_builder_tool("select_agent", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))

    case resolve_owned_agent(user_id, identifier, state.active_agent_id) do
      %{} = agent ->
        result = %{
          "ok" => true,
          "message" => "Selected agent.",
          "agent" => builder_agent_context(agent, state.latest_secret),
          "_ui_group_id" => "builder:agent:#{agent.id}",
          "_ui_cards" => [agent_card_payload(agent, state.latest_secret, "config")]
        }

        {result, %{state | active_agent_id: agent.id}}

      nil ->
        {%{"ok" => false, "error" => "Agent not found."}, state}
    end
  end

  defp execute_builder_tool("update_agent", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))

    with %{} = agent <- resolve_owned_agent(user_id, identifier, state.active_agent_id) do
      attrs =
        input
        |> build_update_attrs()
        |> maybe_apply_generated_prompt(Map.get(input, "description"), agent)

      case Agents.update_agent(agent, attrs, user_id) do
        {:ok, updated} ->
          result = %{
            "ok" => true,
            "message" => "Agent updated.",
            "agent" => builder_agent_context(updated, state.latest_secret),
            "_ui_group_id" => "builder:agent:#{updated.id}",
            "_ui_cards" => [agent_card_payload(updated, state.latest_secret, "config")]
          }

          {result, %{state | active_agent_id: updated.id}}

        {:error, reason} ->
          {%{"ok" => false, "error" => format_reason(reason)}, state}
      end
    else
      nil ->
        {%{"ok" => false, "error" => "Create or select an agent first."}, state}
    end
  end

  defp execute_builder_tool("generate_system_prompt", input, state) do
    description = normalize_optional_string(Map.get(input, "description"))

    enabled_tools =
      normalize_string_list(Map.get(input, "enabled_tools")) || Agents.default_enabled_tools()

    if is_nil(description) do
      {%{"ok" => false, "error" => "description is required"}, state}
    else
      case GroupAgent.generate_system_prompt(description, enabled_tools) do
        {:ok, prompt} ->
          result = %{
            "ok" => true,
            "system_prompt" => prompt,
            "persona_suggestion" => build_persona_suggestion(description),
            "enabled_tools" => enabled_tools
          }

          {result, state}

        {:error, reason} ->
          {%{"ok" => false, "error" => format_reason(reason)}, state}
      end
    end
  end

  defp execute_builder_tool("publish_agent", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))

    with %{} = agent <- resolve_owned_agent(user_id, identifier, state.active_agent_id) do
      case Agents.publish_agent(agent, user_id) do
        {:ok, published} ->
          result = %{
            "ok" => true,
            "message" => "Agent published.",
            "agent" => builder_agent_context(published, state.latest_secret),
            "integration" => integration_payload(published, state.latest_secret),
            "_ui_group_id" => "builder:agent:#{published.id}",
            "_ui_cards" => [agent_card_payload(published, state.latest_secret, "config")]
          }

          {result, %{state | active_agent_id: published.id}}

        {:error, reason} ->
          {%{"ok" => false, "error" => format_reason(reason)}, state}
      end
    else
      nil ->
        {%{"ok" => false, "error" => "Create or select an agent first."}, state}
    end
  end

  defp execute_builder_tool("set_agent_status", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))
    requested_status = normalize_optional_string(Map.get(input, "status")) || "draft"

    with %{} = agent <- resolve_owned_agent(user_id, identifier, state.active_agent_id) do
      result =
        case requested_status do
          "published" ->
            Agents.publish_agent(agent, user_id)

          "disabled" ->
            Agents.update_agent(agent, %{"status" => "disabled"}, user_id)

          "draft" ->
            Agents.update_agent(agent, %{"status" => "draft"}, user_id)

          _ ->
            {:error, :invalid_status}
        end

      case result do
        {:ok, updated} ->
          payload = %{
            "ok" => true,
            "message" => "Agent status updated.",
            "agent" => builder_agent_context(updated, state.latest_secret),
            "_ui_group_id" => "builder:agent:#{updated.id}",
            "_ui_cards" => [agent_card_payload(updated, state.latest_secret, "config")]
          }

          {payload, %{state | active_agent_id: updated.id}}

        {:error, reason} ->
          {%{"ok" => false, "error" => format_reason(reason)}, state}
      end
    else
      nil ->
        {%{"ok" => false, "error" => "Create or select an agent first."}, state}
    end
  end

  defp execute_builder_tool("rotate_secret", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))

    with %{} = agent <- resolve_owned_agent(user_id, identifier, state.active_agent_id) do
      case Agents.rotate_secret(agent, user_id) do
        {:ok, updated, secret} ->
          result = %{
            "ok" => true,
            "message" => "Secret rotated. The secure value is available in the config panel.",
            "secret" => secret,
            "agent" => builder_agent_context(updated, secret),
            "integration" => integration_payload(updated, secret),
            "_ui_group_id" => "builder:agent:#{updated.id}",
            "_ui_cards" => [agent_card_payload(updated, secret, "config")]
          }

          {result, %{state | active_agent_id: updated.id, latest_secret: secret}}

        {:error, reason} ->
          {%{"ok" => false, "error" => format_reason(reason)}, state}
      end
    else
      nil ->
        {%{"ok" => false, "error" => "Create or select an agent first."}, state}
    end
  end

  defp execute_builder_tool("get_integration_details", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))

    case resolve_owned_agent(user_id, identifier, state.active_agent_id) do
      %{} = agent ->
        result = %{
          "ok" => true,
          "integration" => integration_payload(agent, state.latest_secret),
          "agent" => builder_agent_context(agent, state.latest_secret),
          "_ui_group_id" => "builder:agent:#{agent.id}",
          "_ui_cards" => [agent_card_payload(agent, state.latest_secret, "config")]
        }

        {result, state}

      nil ->
        {%{"ok" => false, "error" => "Create or select an agent first."}, state}
    end
  end

  defp execute_builder_tool("ensure_destination_chat", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))
    requested_default = Map.get(input, "set_as_default")

    case resolve_owned_agent(user_id, identifier, state.active_agent_id) do
      %{} = agent ->
        with {:ok, chat_id, chat_status} <- Chat.ensure_dm_chat(user_id, agent.agent_user_id),
             {:ok, updated_agent, default_status} <-
               maybe_set_default_destination_chat(agent, user_id, chat_id, requested_default) do
          result = %{
            "ok" => true,
            "message" => destination_chat_message(chat_id, chat_status, default_status),
            "destination_chat_id" => chat_id,
            "destination_chat_status" => chat_status,
            "default_destination_status" => default_status,
            "destination_chat_open_link" => build_chat_link(chat_id),
            "integration" => integration_payload(updated_agent, state.latest_secret),
            "agent" => builder_agent_context(updated_agent, state.latest_secret),
            "_ui_group_id" => "builder:agent:#{updated_agent.id}",
            "_ui_cards" => [agent_card_payload(updated_agent, state.latest_secret, "config")]
          }

          {result, %{state | active_agent_id: updated_agent.id}}
        else
          {:error, reason} ->
            {%{"ok" => false, "error" => format_reason(reason)}, state}
        end

      nil ->
        {%{"ok" => false, "error" => "Create or select an agent first."}, state}
    end
  end

  defp execute_builder_tool("validate_destination_chat", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))
    provided_chat_id = normalize_optional_string(Map.get(input, "chat_id"))
    repair_default = Map.get(input, "repair_default")

    case resolve_owned_agent(user_id, identifier, state.active_agent_id) do
      %{} = agent ->
        with {:ok, updated_agent, validation} <-
               validate_destination_chat(agent, user_id, provided_chat_id, repair_default) do
          result = %{
            "ok" => true,
            "message" => validation.message,
            "provided_chat_id" => provided_chat_id,
            "provided_chat_status" => validation.provided_status,
            "current_chat_id" => validation.current_chat_id,
            "current_chat" => validation.current_chat,
            "current_destination_kind" => validation.current_destination_kind,
            "current_destination_status" => validation.current_destination_status,
            "default_destination_status" => validation.default_destination_status,
            "destination_chat_open_link" => validation.current_chat["open_link"],
            "integration" => integration_payload(updated_agent, state.latest_secret),
            "agent" => builder_agent_context(updated_agent, state.latest_secret),
            "_ui_group_id" => "builder:agent:#{updated_agent.id}",
            "_ui_cards" => [agent_card_payload(updated_agent, state.latest_secret, "config")]
          }

          {result, %{state | active_agent_id: updated_agent.id}}
        else
          {:error, reason} ->
            {%{"ok" => false, "error" => format_reason(reason)}, state}
        end

      nil ->
        {%{"ok" => false, "error" => "Create or select an agent first."}, state}
    end
  end

  defp execute_builder_tool("archive_agent", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))

    with %{} = agent <- resolve_owned_agent(user_id, identifier, state.active_agent_id) do
      case Agents.archive_agent(agent, user_id) do
        {:ok, archived} ->
          result = %{
            "ok" => true,
            "message" => "Agent removed.",
            "agent" => %{
              "id" => archived.id,
              "display_name" => archived.display_name,
              "status" => archived.status
            }
          }

          {result, %{state | active_agent_id: nil, latest_secret: nil}}

        {:error, reason} ->
          {%{"ok" => false, "error" => format_reason(reason)}, state}
      end
    else
      nil ->
        {%{"ok" => false, "error" => "Create or select an agent first."}, state}
    end
  end

  defp execute_builder_tool(_tool_name, _input, state) do
    {%{"ok" => false, "error" => "Unknown builder tool."}, state}
  end

  defp build_builder_messages(history, message) do
    history
    |> Enum.take(-12)
    |> Enum.map(&normalize_history_message/1)
    |> Enum.reject(&is_nil/1)
    |> Kernel.++([%{role: "user", content: String.slice(String.trim(message), 0, 4_000)}])
  end

  defp normalize_history_message(%{"role" => role, "content" => content})
       when role in ["user", "assistant"] and is_binary(content) do
    %{role: role, content: String.slice(String.trim(content), 0, 4_000)}
  end

  defp normalize_history_message(%{role: role, content: content})
       when role in ["user", "assistant"] and is_binary(content) do
    %{role: role, content: String.slice(String.trim(content), 0, 4_000)}
  end

  defp normalize_history_message(_), do: nil

  defp builder_system_prompt(state) do
    """
    You are @vibeagent, the standalone Vibe agent builder inside the main chat UI.

    Operate in a fully agentic way:
    - Slash input like /newagent, /publish, /secret rotate, /webhook off, or /prompt is only shorthand from the user.
    - Never rely on command parsing. Interpret the message semantically and use tools to do the work.
    - Never claim an agent was created, updated, published, disabled, or rotated unless a tool result confirms it.
    - Use tools whenever you need agent state, ids, URLs, prompts, secrets, attached vibeChatId values, or integration guidance.
    - Before answering setup or integration questions, call get_builder_context or get_integration_details.
    - When the user asks whether a chat id is correct, asks again for the current chat id, says the previous id may be stale or wrong, or asks for a new/current destination, call validate_destination_chat or ensure_destination_chat first. Never answer those from memory or from a prior turn.
    - When the user asks for a chat id or the easiest delivery destination and no attached/default chat is ready yet, call ensure_destination_chat so you can create or reuse the real DM and return its chatId instead of sending the user on a manual lookup flow.
    - When the user describes how the agent should behave, create or update the agent and generate a polished production system prompt.
    - When the user asks about prompt quality, explain that you can read, edit, or generate the prompt and then act with tools.
    - When the user asks how to integrate from code, give exact values from tools: agent_id, user_id, @username, invoke URL, events URL, X-Vibe-Agent-Secret usage, responseMode guidance, vibeChatId values, callback headers, and signature format.
    - The client may render structured agent config cards from tool results. When that happens, keep the text concise and do not dump long env blocks back into chat.
    - When the user asks for the Vibe chat link or chat id, prefer attached_chat_ids, attached_chat_links, and default_destination_chat. Do not present a friendId DM link as if it were an attached chatId.
    - If the live lookup returns the same chat id again, say that explicitly and explain why: Vibe may reuse the same real DM or current default destination, so the correct current id can remain unchanged.
    - When you are not sure about current state, look it up and analyze tool results before you respond. Do not guess, recycle stale ids, or paraphrase uncertain setup details.
    - For setup and integration requests, ask only for true blockers. Treat these as blockers: whether to create a new agent or use an existing one when that is ambiguous, destination chat selection when the user wants delivery inside Vibe and there is no default attached chat, and secret rotation when the current full secret is unavailable.
    - Do NOT ask for low-value polish when the workflow is already clear. Do not ask for channel name, display name, event labels, tone, welcome copy, or message formatting unless the user explicitly asked to customize them or that choice changes functionality. Username is the exception: ask for it whenever the derived handle is taken, or whenever the user cares which link they get.
    - If the user clearly asked to create a new agent and the workflow is already described, create the draft with sensible defaults immediately. Infer a practical display name from the workflow instead of blocking on naming questions.
    - When the user gives a preferred agent name, says the generated name is bad, or asks to rename the agent, always pass display_name explicitly to create_agent or update_agent instead of leaving the old default in place.
    - USERNAMES ARE PUBLIC IDENTITY. The @username becomes the agent's permanent public link (public_link, e.g. vibegram.io/newsroom), so it is derived from the name the user chose — never suffixed with random characters to force it through. If create_agent comes back with username_taken/invalid, tell the user their handle is unavailable, offer the returned `suggestions`, and retry with the one they pick. Use check_agent_username when the user proposes a handle or asks whether one is free.
    - After creating or renaming an agent, tell the user its @username AND its public_link, exactly as the tool returned them. That link is how they share the agent with anyone; never invent, shorten, or retype it.
    - If the user asks for env vars, integration details, or Python/backend setup, always produce a clean integration pack after using tools. Prefer integration_pack_text, env_export_lines, env_vars, and python_event_example from tool results instead of improvising your own shape.
    - When the user wants custom website/app/backend behavior, secure default is code-side customization. Offer the code/env setup path first so the user can control prompts, actions, and backend behavior in their own app instead of asking you to mutate tools or hidden server state.
    - For connected-app requests, ask one concise question only when needed: whether they want the code pack/custom endpoint route, or whether they want you to apply normal agent defaults immediately. If they already asked for code or customization, skip the question and provide the code-oriented setup directly.
    - When default_destination_chat is present, explain that destinationChatId is optional for external event calls. Only require a chat id in the payload when there is no default destination configured.
    - When the user already provided example event types such as trade open, trade close, order created, or signal summary, treat them as sufficient defaults. Do not ask them to restate exact event names unless the user explicitly wants strict naming control.
    - Do not tell the user to use slash commands unless they explicitly ask for slash syntax. Focus on doing the work and explaining outcomes.
    - Never print or paraphrase a full secret in chat. If the current secret is not available anymore, tell the user to rotate it or open the config panel.
    - When the owner asks to remove or delete an agent, archive it with tools instead of explaining how to do it manually.
    - Keep replies concise, practical, and step-by-step when integration is involved.
    - If subagent_mode is true, you are serving another Vibe AI worker. Return direct actionable output instead of UI coaching, and strongly prefer execution plus assumptions over extra clarification when the request is already specific.

    Current client-selected active_agent_id: #{state.active_agent_id || "none"}
    Builder deep link: #{@builder_deep_link}
    Reserved setup handle: @vibeagent
    subagent_mode: #{if(Map.get(state, :subagent_mode), do: "true", else: "false")}
    """
    |> String.trim()
  end

  defp builder_tool_progress_label("get_builder_context", _input),
    do: "Reading your agents…"

  defp builder_tool_progress_label("create_agent", _input),
    do: "Creating draft…"

  defp builder_tool_progress_label("check_agent_username", _input),
    do: "Checking that name…"

  defp builder_tool_progress_label("select_agent", _input),
    do: "Opening agent…"

  defp builder_tool_progress_label("update_agent", _input),
    do: "Updating draft…"

  defp builder_tool_progress_label("publish_agent", _input),
    do: "Publishing agent…"

  defp builder_tool_progress_label("generate_system_prompt", _input),
    do: "Writing prompt…"

  defp builder_tool_progress_label("set_agent_status", _input),
    do: "Updating status…"

  defp builder_tool_progress_label("archive_agent", _input),
    do: "Removing agent…"

  defp builder_tool_progress_label("rotate_secret", _input),
    do: "Rotating secret…"

  defp builder_tool_progress_label("get_integration_details", _input),
    do: "Reading integration…"

  defp builder_tool_progress_label("ensure_destination_chat", _input),
    do: "Preparing chat…"

  defp builder_tool_progress_label("validate_destination_chat", _input),
    do: "Re-checking chat…"

  defp builder_tool_progress_label(_tool_name, _input),
    do: "Setting up agent…"

  defp build_create_attrs(input) do
    %{}
    |> maybe_put(
      "display_name",
      inferred_create_display_name(input)
    )
    |> maybe_put("username", normalize_optional_string(Map.get(input, "username")))
    |> maybe_put("system_prompt", normalize_optional_string(Map.get(input, "system_prompt")))
    |> maybe_put("persona", normalize_optional_string(Map.get(input, "persona")))
    |> maybe_put("model_provider", normalize_optional_string(Map.get(input, "model_provider")))
    |> maybe_put("model_id", normalize_optional_string(Map.get(input, "model_id")))
    |> maybe_put("callback_url", normalize_callback_input(Map.get(input, "callback_url")))
    |> maybe_put("enabled_tools", normalize_string_list(Map.get(input, "enabled_tools")))
    |> maybe_put("output_modes", normalize_string_list(Map.get(input, "output_modes")))
    |> maybe_put("voice_profile", normalize_optional_string(Map.get(input, "voice_profile")))
  end

  defp build_update_attrs(input) do
    %{}
    |> maybe_put("display_name", normalize_optional_string(Map.get(input, "display_name")))
    |> maybe_put("username", normalize_optional_string(Map.get(input, "username")))
    |> maybe_put("system_prompt", normalize_optional_string(Map.get(input, "system_prompt")))
    |> maybe_put("persona", normalize_optional_string(Map.get(input, "persona")))
    |> maybe_put("model_provider", normalize_optional_string(Map.get(input, "model_provider")))
    |> maybe_put("model_id", normalize_optional_string(Map.get(input, "model_id")))
    |> maybe_put("callback_url", normalize_callback_input(Map.get(input, "callback_url")))
    |> maybe_put("enabled_tools", normalize_string_list(Map.get(input, "enabled_tools")))
    |> maybe_put("output_modes", normalize_string_list(Map.get(input, "output_modes")))
    |> maybe_put("voice_profile", normalize_optional_string(Map.get(input, "voice_profile")))
    |> maybe_put("welcome_message", normalize_optional_string(Map.get(input, "welcome_message")))
  end

  defp inferred_create_display_name(input) do
    normalize_optional_string(Map.get(input, "display_name")) ||
      normalize_optional_string(Map.get(input, "name")) ||
      infer_display_name_from_text(Map.get(input, "description")) ||
      infer_display_name_from_text(Map.get(input, "persona")) ||
      "New Agent"
  end

  defp infer_display_name_from_text(value) do
    text = normalize_optional_string(value)

    with true <- is_binary(text) do
      candidate =
        text
        |> String.split(~r/[.!?\n]/, parts: 2)
        |> List.first()
        |> normalize_optional_string()
        |> strip_display_name_prefixes()
        |> case do
          nil -> nil
          trimmed -> trimmed |> String.trim(" -,:;") |> normalize_optional_string()
        end

      candidate
      |> case do
        nil ->
          nil

        phrase ->
          words =
            phrase
            |> String.split(~r/\s+/, trim: true)
            |> Enum.take(4)

          title =
            words
            |> Enum.map(&String.capitalize/1)
            |> Enum.join(" ")
            |> normalize_optional_string()

          cond do
            is_nil(title) ->
              nil

            Regex.match?(~r/\b(agent|assistant|bot)\b/i, title) ->
              title

            true ->
              "#{title} Agent"
          end
          |> case do
            nil ->
              nil

            inferred ->
              inferred |> String.slice(0, 48) |> String.trim() |> normalize_optional_string()
          end
      end
    else
      _ -> nil
    end
  end

  defp strip_display_name_prefixes(nil), do: nil

  defp strip_display_name_prefixes(text) do
    text
    |> String.replace(
      ~r/^(i\s+(need|want)\s+|please\s+)?(create|build|make|set\s*up|setup)\s+(me\s+|us\s+|a\s+|an\s+)?/i,
      ""
    )
    |> String.replace(~r/^(an?\s+)?(agent|assistant|bot)\s+(for|that|to)\s+/i, "")
    |> String.replace(~r/^(for|about)\s+/i, "")
    |> normalize_optional_string()
  end

  defp maybe_apply_generated_prompt(attrs, nil), do: attrs

  defp maybe_apply_generated_prompt(attrs, description) do
    maybe_apply_generated_prompt(attrs, description, nil)
  end

  defp maybe_apply_generated_prompt(attrs, description, agent) do
    description = normalize_optional_string(description)

    cond do
      is_nil(description) ->
        attrs

      Map.get(attrs, "system_prompt") && String.trim(Map.get(attrs, "system_prompt")) != "" ->
        attrs

      true ->
        enabled_tools =
          Map.get(attrs, "enabled_tools") ||
            if(agent, do: agent.enabled_tools, else: nil) ||
            Agents.default_enabled_tools()

        case GroupAgent.generate_system_prompt(description, enabled_tools) do
          {:ok, generated_prompt} ->
            attrs
            |> Map.put("system_prompt", generated_prompt)
            |> Map.put_new("persona", build_persona_suggestion(description))

          {:error, _reason} ->
            attrs
        end
    end
  end

  defp resolve_owned_agent(user_id, identifier, active_agent_id) do
    normalized_identifier = normalize_optional_string(identifier)

    cond do
      is_binary(normalized_identifier) ->
        find_owned_agent(user_id, normalized_identifier)

      is_binary(active_agent_id) ->
        Agents.get_agent(active_agent_id, user_id)

      true ->
        nil
    end
  end

  defp find_owned_agent(user_id, identifier) do
    Agents.get_agent(identifier, user_id) ||
      case Agents.get_agent_by_username(identifier) do
        %{} = agent when agent.owner_user_id == user_id -> agent
        _ -> nil
      end
  end

  defp builder_context_payload(user_id, agent, latest_secret) do
    %{
      "builder" => %{
        "handle" => "@vibeagent",
        "deep_link" => @builder_deep_link,
        "slash_mode" => "optional"
      },
      "quota" => Agents.quota_for_user(user_id),
      "default_enabled_tools" => Agents.default_enabled_tools(),
      "default_output_modes" => Agents.default_output_modes(),
      "available_tools" => Enum.map(ToolRegistry.tools(), &tool_catalog_payload/1),
      "agents" => Enum.map(Agents.list_agents(user_id), &agent_list_payload/1),
      "active_agent" => if(agent, do: builder_agent_context(agent, latest_secret), else: nil)
    }
  end

  defp tool_catalog_payload(tool) do
    %{
      "id" => tool.id,
      "name" => tool.name,
      "description" => tool.description
    }
  end

  defp agent_list_payload(agent) do
    payload = Agents.agent_payload(agent)

    %{
      "id" => payload.id,
      "display_name" => payload.displayName,
      "username" => payload.username,
      "status" => payload.status,
      "has_prompt" => String.trim(payload.systemPrompt || "") != ""
    }
  end

  defp builder_agent_context(agent, latest_secret) do
    payload = Agents.agent_payload(agent)
    attached_chat_links = build_attached_chat_links(payload.attachedChats || [])
    default_chat = resolve_default_chat(payload.defaultDestinationChatId, attached_chat_links)

    %{
      "agent" => payload,
      "prompt_status" => prompt_status_line(agent),
      "open_link" => default_chat && default_chat["open_link"],
      "agent_dm_link" => build_agent_dm_link(payload.userId),
      "public_link" => payload.publicLink,
      "builder_link" => @builder_deep_link,
      "integration" => integration_payload(agent, latest_secret)
    }
  end

  defp integration_payload(agent, latest_secret) do
    payload = Agents.agent_payload(agent)
    attached_chat_links = build_attached_chat_links(payload.attachedChats || [])
    default_chat = resolve_default_chat(payload.defaultDestinationChatId, attached_chat_links)
    base_url = public_base_url()
    chat_id_optional = not is_nil(default_chat)
    destination_chat_env_value = if(default_chat, do: nil, else: "<set_if_no_default_chat>")

    env_export_lines =
      build_env_export_lines(
        payload,
        base_url,
        latest_secret,
        destination_chat_env_value,
        chat_id_optional
      )

    integration_pack_text =
      build_integration_pack_text(
        agent,
        payload,
        base_url,
        env_export_lines,
        chat_id_optional,
        default_chat
      )

    %{
      "agent_id" => payload.id,
      "user_id" => payload.userId,
      "username" => payload.username,
      "display_name" => payload.displayName,
      "status" => payload.status,
      "open_link" => default_chat && default_chat["open_link"],
      "agent_dm_link" => build_agent_dm_link(payload.userId),
      "builder_link" => @builder_deep_link,
      "api_base_url" => base_url,
      "invoke_url" => build_invoke_url(agent),
      "events_url" => build_events_url(agent),
      "secret_hint" => payload.secretHint,
      "latest_secret" => latest_secret,
      "secret_note" =>
        if(is_binary(latest_secret),
          do: "Use the latest_secret value below.",
          else:
            "The full secret is only shown right after creation or rotation. Rotate it if you need a new copy."
        ),
      "auth_header" => %{"X-Vibe-Agent-Secret" => latest_secret || "<rotate_secret_to_reveal>"},
      "env_vars" => %{
        "VIBE_API_BASE_URL" => base_url,
        "VIBE_AGENT_IDENTIFIER" => payload.username || payload.id,
        "VIBE_AGENT_SECRET" => latest_secret || "<rotate_secret_to_reveal>",
        "VIBE_DESTINATION_CHAT_ID" => destination_chat_env_value,
        "VIBE_SOURCE" => "external_app",
        "VIBE_TIMEOUT_SECONDS" => "10"
      },
      "env_export_lines" => env_export_lines,
      "env_var_notes" => %{
        "VIBE_DESTINATION_CHAT_ID" =>
          if(chat_id_optional,
            do: "Optional because this agent already has a default destination chat in Vibe.",
            else:
              "Optional only after you attach or configure a default destination chat in Vibe."
          )
      },
      "connected_app_route_example" => %{
        "endpoint_url" => "https://your-app.example.com/api/vibe/agent-actions",
        "allowed_actions" => [
          "website.summary",
          "website.funnel.summary",
          "website.live_presence",
          "waitlist.summary",
          "engine.usage.summary"
        ],
        "static_params" => %{
          "workspace" => "trade"
        },
        "timeout_ms" => 10_000
      },
      "connected_app_route_notes" => [
        "Use a narrow app-owned POST endpoint and validate x-vibe-integration-secret on your side.",
        "Expose only explicit action ids your app supports; do not forward arbitrary SQL, raw code, or unrestricted tool execution.",
        "This keeps prompt/tool customization in your own app code instead of requiring hidden server-side tool creation."
      ],
      "recommended_endpoint" => build_events_url(agent),
      "recommended_identifier" => payload.username || payload.id,
      "request_body_examples" => %{
        "reply" => %{
          "source" => "external",
          "message" => "Hello",
          "responseMode" => "reply"
        },
        "send" => %{
          "source" => "external",
          "vibeChatId" => "<attached_chat_id>",
          "message" => "Hello",
          "responseMode" => "send"
        },
        "event" => %{
          "eventId" => "evt_123",
          "eventType" => "order.created",
          "threadKey" => "order_123",
          "source" => "shopify",
          "title" => "New order paid",
          "text" => "Sara paid $240 for 3 items",
          "data" => %{
            "orderId" => "123",
            "amount" => 240,
            "currency" => "USD",
            "status" => "paid"
          }
        }
      },
      "python_event_example" => [
        "import os, requests",
        "",
        "url = \"#{build_events_url(agent)}\"",
        "headers = {\"X-Vibe-Agent-Secret\": os.environ[\"VIBE_AGENT_SECRET\"]}",
        "payload = {",
        "    \"eventId\": \"evt_123\",",
        "    \"eventType\": \"trade.opened\",",
        "    \"threadKey\": \"trade_123\",",
        "    \"source\": os.getenv(\"VIBE_SOURCE\", \"external_app\"),",
        "    \"title\": \"Trade opened\",",
        "    \"text\": \"EURUSD buy opened at 1.0850\",",
        "    \"data\": {\"symbol\": \"EURUSD\", \"side\": \"buy\", \"entry\": 1.0850}",
        "}",
        if(chat_id_optional,
          do:
            "# destinationChatId is optional because the agent already has a default Vibe destination chat.",
          else:
            "# Add destinationChatId only if you have not set a default destination chat in Vibe yet."
        ),
        "response = requests.post(url, json=payload, headers=headers, timeout=float(os.getenv(\"VIBE_TIMEOUT_SECONDS\", \"10\")))",
        "response.raise_for_status()"
      ],
      "integration_pack_text" => integration_pack_text,
      "destination_chat_required" => not chat_id_optional,
      "default_destination_chat" => default_chat,
      "attached_chats" => payload.attachedChats || [],
      "attached_chat_ids" => Enum.map(attached_chat_links, & &1["chat_id"]),
      "attached_chat_links" => attached_chat_links,
      "callback_url" => payload.callbackUrl,
      "callback_headers" => [
        "X-Vibe-Agent-Signature-Timestamp",
        "X-Vibe-Agent-Signature"
      ],
      "callback_signature" => "hex(hmac_sha256(secret, \"<timestamp>.<raw_body>\"))",
      "notes" => [
        "Use responseMode=reply for stateless replies returned directly to your backend.",
        "Use responseMode=send only when the agent is already attached to the target Vibe chat.",
        "Use the events_url when you want structured event threads like orders, trades, tickets, and alerts inside Vibe chats.",
        if(chat_id_optional,
          do:
            "This agent already has a default destination chat, so destinationChatId is optional for event ingestion.",
          else:
            "If no default destination chat is configured yet, you must attach the agent to a Vibe chat or pass destinationChatId until you do."
        ),
        "Use attached_chat_links and attached_chat_ids for real Vibe destinations. The agent_dm_link only opens a DM and is not the same as an attached chatId.",
        "To get a vibeChatId, DM the agent or invite it into a group/channel first."
      ]
    }
  end

  defp build_env_export_lines(
         payload,
         base_url,
         latest_secret,
         destination_chat_env_value,
         chat_id_optional
       ) do
    base_lines = [
      "VIBE_API_BASE_URL=#{base_url}",
      "VIBE_AGENT_IDENTIFIER=#{payload.username || payload.id}",
      "VIBE_AGENT_SECRET=#{latest_secret || "<rotate_secret_to_reveal>"}",
      "VIBE_SOURCE=external_app",
      "VIBE_TIMEOUT_SECONDS=10"
    ]

    destination_line =
      if chat_id_optional do
        "# VIBE_DESTINATION_CHAT_ID is optional because this agent already has a default Vibe destination chat."
      else
        "VIBE_DESTINATION_CHAT_ID=#{destination_chat_env_value}"
      end

    base_lines ++ [destination_line]
  end

  defp build_integration_pack_text(
         agent,
         payload,
         base_url,
         env_export_lines,
         chat_id_optional,
         default_chat
       ) do
    identifier = payload.username || payload.id

    destination_line =
      if chat_id_optional do
        "Default destination chat: configured#{if(default_chat && default_chat["chat_id"], do: " (#{default_chat["chat_id"]})", else: "")}"
      else
        "Default destination chat: not configured yet"
      end

    [
      "Use this API base URL: #{base_url}",
      "Use this agent identifier: #{identifier}",
      "Send structured events to: #{build_events_url(agent)}",
      destination_line,
      "Set these env vars:",
      Enum.map(env_export_lines, &"  #{&1}")
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp extract_chat_id(chat) when is_map(chat) do
    chat[:chatId] || chat["chatId"] || chat[:chat_id] || chat["chat_id"]
  end

  defp extract_chat_id(_chat), do: nil

  defp build_attached_chat_links(chats) do
    chats
    |> Enum.map(fn chat ->
      chat_id = extract_chat_id(chat)

      if is_binary(chat_id) do
        %{
          "chat_id" => chat_id,
          "name" => chat[:name] || chat["name"],
          "type" => chat[:type] || chat["type"],
          "open_link" => build_chat_link(chat_id)
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_default_chat(default_chat_id, attached_chat_links) do
    desired_id = normalize_optional_string(default_chat_id)

    cond do
      is_binary(desired_id) ->
        Enum.find(attached_chat_links, fn chat -> chat["chat_id"] == desired_id end)

      attached_chat_links != [] ->
        List.first(attached_chat_links)

      true ->
        nil
    end
  end

  defp find_visible_default_chat(default_chat_id, attached_chat_links) do
    desired_id = normalize_optional_string(default_chat_id)

    if is_binary(desired_id) do
      Enum.find(attached_chat_links, fn chat -> chat["chat_id"] == desired_id end)
    end
  end

  defp build_chat_link(chat_id) when is_binary(chat_id) do
    "vibe://chat?chatId=#{chat_id}"
  end

  defp build_chat_link(_chat_id), do: nil

  defp maybe_set_default_destination_chat(agent, user_id, chat_id, requested_default) do
    current_default_id = normalize_optional_string(agent.default_destination_chat_id)

    current_default_visible =
      Agents.attached_chats(agent)
      |> Enum.any?(fn chat ->
        normalize_optional_string(chat[:chatId] || chat["chatId"]) == current_default_id
      end)

    should_set_default =
      case requested_default do
        true -> true
        false -> false
        _ -> not is_binary(current_default_id) or not current_default_visible
      end

    cond do
      not should_set_default ->
        {:ok, agent, "unchanged"}

      current_default_id == chat_id ->
        {:ok, agent, "already_set"}

      true ->
        case Agents.update_agent(agent, %{"default_destination_chat_id" => chat_id}, user_id) do
          {:ok, updated_agent} -> {:ok, updated_agent, "updated"}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp destination_chat_message(chat_id, chat_status, default_status) do
    base =
      case chat_status do
        "created" -> "Created a Vibe DM and collected its chat id: #{chat_id}."
        "restored" -> "Restored the Vibe DM and collected its chat id: #{chat_id}."
        _ -> "Found the existing Vibe chat id: #{chat_id}."
      end

    suffix =
      case default_status do
        "updated" -> " I also set it as the default destination for events."
        "already_set" -> " It was already the default destination."
        _ -> ""
      end

    base <> suffix
  end

  defp validate_destination_chat(agent, user_id, provided_chat_id, repair_default) do
    should_repair_default = repair_default != false
    payload = Agents.agent_payload(agent)
    attached_chat_links = build_attached_chat_links(payload.attachedChats || [])

    visible_default_chat =
      find_visible_default_chat(payload.defaultDestinationChatId, attached_chat_links)

    cond do
      visible_default_chat ->
        {:ok, agent,
         build_destination_validation_result(
           visible_default_chat,
           attached_chat_links,
           provided_chat_id,
           "existing",
           "unchanged",
           "default"
         )}

      attached_chat_links != [] ->
        current_chat = List.first(attached_chat_links)

        if should_repair_default do
          case Agents.update_agent(
                 agent,
                 %{"default_destination_chat_id" => current_chat["chat_id"]},
                 user_id
               ) do
            {:ok, updated_agent} ->
              refreshed_payload = Agents.agent_payload(updated_agent)
              refreshed_links = build_attached_chat_links(refreshed_payload.attachedChats || [])

              refreshed_chat =
                find_visible_default_chat(
                  refreshed_payload.defaultDestinationChatId,
                  refreshed_links
                ) ||
                  List.first(refreshed_links) ||
                  current_chat

              {:ok, updated_agent,
               build_destination_validation_result(
                 refreshed_chat,
                 refreshed_links,
                 provided_chat_id,
                 "existing",
                 "updated",
                 "attached"
               )}

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:ok, agent,
           build_destination_validation_result(
             current_chat,
             attached_chat_links,
             provided_chat_id,
             "existing",
             "unchanged",
             "attached"
           )}
        end

      true ->
        with {:ok, chat_id, chat_status} <- Chat.ensure_dm_chat(user_id, agent.agent_user_id),
             {:ok, updated_agent, default_status} <-
               maybe_set_default_destination_chat(agent, user_id, chat_id, should_repair_default) do
          refreshed_payload = Agents.agent_payload(updated_agent)
          refreshed_links = build_attached_chat_links(refreshed_payload.attachedChats || [])

          current_chat =
            Enum.find(refreshed_links, fn chat -> chat["chat_id"] == chat_id end) ||
              %{
                "chat_id" => chat_id,
                "name" =>
                  refreshed_payload.displayName || refreshed_payload.username || "Agent DM",
                "type" => "dm",
                "open_link" => build_chat_link(chat_id)
              }

          {:ok, updated_agent,
           build_destination_validation_result(
             current_chat,
             refreshed_links,
             provided_chat_id,
             chat_status,
             default_status,
             "ensured"
           )}
        end
    end
  end

  defp build_destination_validation_result(
         current_chat,
         attached_chat_links,
         provided_chat_id,
         current_destination_status,
         default_destination_status,
         current_destination_kind
       ) do
    current_chat_id = current_chat["chat_id"]

    provided_status =
      cond do
        not is_binary(provided_chat_id) ->
          "not_provided"

        provided_chat_id == current_chat_id ->
          "matches_current"

        Enum.any?(attached_chat_links, fn chat -> chat["chat_id"] == provided_chat_id end) ->
          "attached_but_not_current"

        true ->
          "not_found"
      end

    %{
      current_chat_id: current_chat_id,
      current_chat: current_chat,
      current_destination_kind: current_destination_kind,
      current_destination_status: current_destination_status,
      default_destination_status: default_destination_status,
      provided_status: provided_status,
      message:
        destination_validation_message(
          current_chat,
          provided_chat_id,
          provided_status,
          current_destination_status,
          default_destination_status,
          current_destination_kind
        )
    }
  end

  defp destination_validation_message(
         current_chat,
         provided_chat_id,
         provided_status,
         current_destination_status,
         default_destination_status,
         current_destination_kind
       ) do
    current_chat_id = current_chat["chat_id"]

    base =
      case provided_status do
        "matches_current" ->
          "I re-checked live state. #{provided_chat_id} is still the correct destination chat id."

        "attached_but_not_current" ->
          "I re-checked live state. #{provided_chat_id} is attached and visible, but the current destination chat id is #{current_chat_id}."

        "not_found" ->
          "I re-checked live state. #{provided_chat_id} is not a current owner-visible destination for this agent. The correct chat id is #{current_chat_id}."

        _ ->
          case current_destination_status do
            "created" ->
              "I created the real Vibe destination chat and its chat id is #{current_chat_id}."

            "restored" ->
              "I restored the real Vibe destination chat and its chat id is #{current_chat_id}."

            _ ->
              "I re-checked live state. The current destination chat id is #{current_chat_id}."
          end
      end

    reuse_note =
      if provided_status == "matches_current" and
           (current_destination_kind in ["default", "ensured"] ||
              current_chat["type"] == "dm") do
        " Vibe can reuse the same real DM or current default destination, so asking again can return the same id when it is still correct."
      else
        ""
      end

    default_note =
      case default_destination_status do
        "updated" ->
          " I also updated the agent's default destination to that chat."

        "already_set" ->
          " It is already the default destination."

        _ ->
          ""
      end

    base <> reuse_note <> default_note
  end

  defp build_agent_dm_link(user_id) when is_binary(user_id) do
    "vibe://chat?friendId=#{user_id}"
  end

  defp build_agent_dm_link(_user_id), do: nil

  defp build_invoke_url(agent) do
    base = public_base_url()
    path = "/api/agents/#{agent.id}/invoke"

    if base == "" do
      path
    else
      String.trim_trailing(base, "/") <> path
    end
  end

  defp build_events_url(agent) do
    base = public_base_url()
    path = "/api/agents/#{agent.id}/events"

    if base == "" do
      path
    else
      String.trim_trailing(base, "/") <> path
    end
  end

  defp public_base_url do
    System.get_env("PUBLIC_BASE_URL") ||
      System.get_env("API_BASE_URL") ||
      endpoint_url()
  end

  defp endpoint_url do
    try do
      VibeWeb.Endpoint.url()
    rescue
      _ -> ""
    end
  end

  defp default_suggestions(nil) do
    [
      "I need an agent for my shoes store.",
      "Set up an order operations agent and ask only what you need.",
      "Create a customer support agent with a publish-ready draft.",
      "How do I call this agent from my backend and webhook?"
    ]
  end

  defp default_suggestions(agent) do
    if String.trim(agent.system_prompt || "") == "" do
      [
        "Write the system prompt for an agent that books salon appointments.",
        "Make this agent sound like a calm legal intake assistant.",
        "Publish this agent when it is ready.",
        "Show me the invoke URL and chat ids I can use."
      ]
    else
      [
        "How do I integrate this agent from code?",
        "Rotate the secret for this agent.",
        "Disable callbacks for now.",
        "Publish this agent."
      ]
    end
  end

  defp prompt_status_line(agent) do
    if String.trim(agent.system_prompt || "") == "" do
      "No prompt yet. I can read, edit, or generate it from plain language."
    else
      "Prompt is ready. I can still rewrite it, add character, or tighten the instructions."
    end
  end

  defp fallback_reply(nil) do
    "Tell me what kind of agent you want and I’ll build it here."
  end

  defp fallback_reply(agent) do
    "Updated #{agent.display_name}. #{prompt_status_line(agent)}"
  end

  defp build_persona_suggestion(description) do
    description
    |> to_string()
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.slice(0, 140)
  end

  defp normalize_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, inner_value}, acc ->
      Map.put(acc, key, inner_value)
    end)
  end

  defp normalize_map(_value), do: %{}

  defp normalize_callback_input(nil), do: nil

  defp normalize_callback_input(value) when is_binary(value) do
    trimmed = String.trim(value)

    case String.downcase(trimmed) do
      "" -> nil
      "off" -> nil
      "disable" -> nil
      "disabled" -> nil
      _ -> trimmed
    end
  end

  defp normalize_callback_input(value) do
    value
    |> to_string()
    |> normalize_callback_input()
  end

  defp normalize_string_list(nil), do: nil

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      items -> items
    end
  end

  defp normalize_string_list(value) when is_binary(value) do
    value
    |> String.split(~r/[\n,|]/, trim: true)
    |> normalize_string_list()
  end

  defp normalize_string_list(_), do: nil

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(value) do
    value
    |> to_string()
    |> normalize_optional_string()
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit_builder_ui(callback, %{"_ui_cards" => cards} = result)
       when is_function(callback, 1) and is_list(cards) and cards != [] do
    callback.(%{
      type: :agent_cards,
      group_id: result["_ui_group_id"] || "builder:cards",
      cards: cards
    })
  end

  defp emit_builder_ui(_callback, _result), do: :ok

  defp builder_tool_model_result(result) when is_map(result) do
    cards = Map.get(result, "_ui_cards")

    if is_list(cards) and cards != [] do
      agent =
        result
        |> Map.get("agent", %{})
        |> compact_agent_model_context()

      %{
        "ok" => Map.get(result, "ok", true),
        "message" =>
          Map.get(result, "message") ||
            "The agent details and integration pack are available in the interactive card.",
        "agent" => agent,
        "ui_card_rendered" => true,
        "response_instruction" =>
          "Reply with one short confirmation. Do not repeat IDs, URLs, secrets, env vars, or endpoint lists in chat."
      }
      |> sanitize_builder_payload()
    else
      result
      |> Map.delete("_ui_cards")
      |> Map.delete("_ui_group_id")
      |> sanitize_builder_payload()
    end
  end

  defp builder_tool_model_result(result), do: result

  defp compact_agent_model_context(%{} = context) do
    payload = Map.get(context, "agent", context)

    %{
      "display_name" =>
        payload[:displayName] || payload["displayName"] || payload["display_name"],
      "username" => payload[:username] || payload["username"],
      "status" => payload[:status] || payload["status"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp compact_agent_model_context(_context), do: %{}

  defp sanitize_builder_payload(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp sanitize_builder_payload(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp sanitize_builder_payload(%Date{} = value), do: Date.to_iso8601(value)
  defp sanitize_builder_payload(%Time{} = value), do: Time.to_iso8601(value)
  defp sanitize_builder_payload(%Decimal{} = value), do: Decimal.to_string(value)
  defp sanitize_builder_payload(value) when is_struct(value), do: inspect(value)

  defp sanitize_builder_payload(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, inner_value}, acc ->
      key_string = to_string(key)

      cond do
        String.starts_with?(key_string, "_") ->
          acc

        key_string in ["secret", "latest_secret"] ->
          acc

        key_string == "auth_header" and is_map(inner_value) ->
          Map.put(acc, key, %{"X-Vibe-Agent-Secret" => "<available_in_config_panel>"})

        true ->
          Map.put(acc, key, sanitize_builder_payload(inner_value))
      end
    end)
  end

  defp sanitize_builder_payload(value) when is_list(value) do
    Enum.map(value, &sanitize_builder_payload/1)
  end

  defp sanitize_builder_payload(value) when is_binary(value) do
    value
    |> String.replace(~r/vas_[A-Za-z0-9_\-]+/, "<available_in_config_panel>")
    |> String.replace(~r/VIBE_AGENT_SECRET=.+/, "VIBE_AGENT_SECRET=<available_in_config_panel>")
  end

  defp sanitize_builder_payload(value), do: value

  defp build_agent_cards_payloads(agents, active_agent_id, latest_secret) do
    agents
    |> Enum.map(fn agent ->
      style = if agent.id == active_agent_id, do: "config", else: "summary"
      secret = if style == "config", do: latest_secret, else: nil
      agent_card_payload(agent, secret, style)
    end)
  end

  defp agent_card_payload(agent, latest_secret, style) do
    payload = Agents.agent_payload(agent)
    integration = integration_payload(agent, latest_secret)

    %{
      "id" => "agent-card:#{payload.id}:#{style}",
      "style" => style,
      "agent_id" => payload.id,
      "agent_user_id" => payload.userId,
      "display_name" => payload.displayName || "Agent",
      "username" => payload.username,
      "handle" => if(payload.username, do: "@#{payload.username}", else: nil),
      "identifier" => payload.username || payload.id,
      "status" => payload.status,
      "prompt_status" => prompt_status_line(agent),
      "prompt_preview" => condensed_prompt_preview(payload.systemPrompt),
      "system_prompt" => payload.systemPrompt,
      "enabled_tools" => payload.enabledTools || [],
      "output_modes" => payload.outputModes || [],
      "voice_profile" => payload.voiceProfile,
      "callback_url" => payload.callbackUrl,
      "api_base_url" => integration["api_base_url"],
      "invoke_url" => integration["invoke_url"],
      "events_url" => integration["events_url"],
      "builder_link" => integration["builder_link"],
      "agent_dm_link" => integration["agent_dm_link"],
      "default_destination_chat" => integration["default_destination_chat"],
      "attached_chats" => integration["attached_chat_links"] || [],
      "event_inbox_mode" =>
        get_in(payload.approvalRules || %{}, ["event_inbox", "mode"]) || "per_event",
      "summary_window_hours" =>
        get_in(payload.approvalRules || %{}, ["event_inbox", "summary_window_hours"]) || 24,
      "incoming_chat_enabled" => Agents.incoming_chat_enabled?(agent),
      "secret_hint" => payload.secretHint,
      "latest_secret" => latest_secret,
      "can_delete" => true
    }
  end

  defp condensed_prompt_preview(prompt) when is_binary(prompt) do
    prompt
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> case do
      "" -> nil
      text -> String.slice(text, 0, 180)
    end
  end

  defp condensed_prompt_preview(_prompt), do: nil
end
