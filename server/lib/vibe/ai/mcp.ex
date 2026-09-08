defmodule Vibe.AI.MCP do
  @moduledoc """
  Entry point for Model Context Protocol support.
  """

  require Logger

  alias Vibe.Agent, as: AgentSchema
  alias Vibe.Agents
  alias Vibe.Chat
  alias Vibe.AI.MCP.Client
  alias Vibe.AI.MCP.Content
  alias Vibe.AI.MCP.Registry

  @gate_tool_id "call_mcp_tool"

  defdelegate servers(agent), to: Registry
  defdelegate prompt_guidance(agent), to: Registry
  defdelegate mcp_tool_name?(name), to: Registry
  defdelegate invalidate(agent), to: Registry

  @doc "The registry tool id that gates MCP access for an agent, group, or channel."
  def gate_tool_id, do: @gate_tool_id

  @doc """
  Discovered MCP tools shaped like the agent's built-in tool maps (`%{name:.
  """
  def tool_specs(%AgentSchema{} = agent) do
    agent
    |> Registry.tools()
    |> Enum.map(fn tool ->
      %{
        name: tool.name,
        description: describe(tool),
        input_schema: normalize_schema(tool.input_schema)
      }
    end)
  end

  def tool_specs(_agent), do: []

  @doc """
  Runs one namespaced MCP tool on behalf of an agent, in a specific chat.
  """
  def invoke(tool_name, arguments, agent_id, requester_user_id, chat_id \\ nil) do
    with {:ok, agent} <- authorize(agent_id, requester_user_id, chat_id),
         {:ok, tool} <- Registry.resolve(agent, tool_name),
         {:ok, raw} <- Client.call_tool(tool.server, tool.remote_name, arguments || %{}) do
      normalized =
        Content.normalize(raw, owner_id: agent.owner_user_id, server_name: tool.server.name)

      Logger.info(
        "[MCP] call server=#{tool.server.name} tool=#{tool.remote_name} " <>
          "agent=#{agent.id} requester=#{redact_id(requester_user_id)} chat=#{redact_id(chat_id)} " <>
          "files=#{length(normalized.outputs)} error=#{normalized.is_error}"
      )

      payload = %{
        "ok" => not normalized.is_error,
        "server" => tool.server.name,
        "tool" => tool.remote_name,
        "summary" => normalized.text,
        "files" => Enum.map(normalized.outputs, &file_descriptor/1)
      }

      payload =
        case normalized.structured do
          value when is_map(value) -> Map.put(payload, "data", value)
          _ -> payload
        end

      if normalized.is_error do
        Map.put(payload, "error", normalized.text)
      else
        payload
      end
    else
      {:error, reason} -> error_payload(tool_name, reason)
    end
  end

  @doc """
  Rebuilds delivery outputs from an MCP tool result.
  """
  def outputs_from_result(result) when is_map(result) do
    result
    |> Map.get("files", Map.get(result, :files, []))
    |> List.wrap()
    |> Enum.map(&output_from_file/1)
    |> Enum.reject(&is_nil/1)
  end

  def outputs_from_result(_result), do: []

  defp output_from_file(file) when is_map(file) do
    url = file["url"] || file[:url]
    mime = file["mimeType"] || file[:mimeType] || "application/octet-stream"
    name = file["fileName"] || file[:fileName]

    if is_binary(url) and url != "" do
      %{
        type: output_type(mime),
        mediaUrl: url,
        metadata: %{"fileName" => name, "mimeType" => mime, "source" => "mcp"}
      }
    end
  end

  defp output_from_file(_file), do: nil

  defp output_type("image/" <> _), do: "image"
  defp output_type("audio/" <> _), do: "audio"
  defp output_type(_), do: "file"

  defp file_descriptor(output) do
    metadata = Map.get(output, :metadata, %{})

    %{
      "fileName" => metadata["fileName"],
      "mimeType" => metadata["mimeType"],
      "byteCount" => metadata["byteCount"],
      "url" => Map.get(output, :mediaUrl)
    }
  end

  defp authorize(agent_id, requester_user_id, chat_id)
       when is_binary(agent_id) and is_binary(chat_id) and is_binary(requester_user_id) do
    with %AgentSchema{} = agent <- Agents.get_agent(agent_id, nil),
         true <- requester_in_chat?(chat_id, requester_user_id, agent),
         {:ok, policy} <- Chat.effective_agent_policy(chat_id, agent, requester_user_id),
         true <- @gate_tool_id in (Map.get(policy, :enabled_tools) || []) do
      {:ok, agent}
    else
      false -> {:error, :not_permitted_here}
      {:error, :chat_not_attached} -> {:error, :chat_not_attached}
      _ -> {:error, :agent_not_available}
    end
  end

  defp authorize(agent_id, requester_user_id, nil)
       when is_binary(agent_id) and is_binary(requester_user_id) do
    case Agents.get_agent(agent_id, requester_user_id) do
      %AgentSchema{enabled_tools: tools} = agent ->
        if @gate_tool_id in (tools || []) do
          {:ok, agent}
        else
          {:error, :not_permitted_here}
        end

      _ ->
        {:error, :agent_not_available}
    end
  end

  defp authorize(_agent_id, _requester_user_id, _chat_id), do: {:error, :owner_lookup_required}

  defp requester_in_chat?(_chat_id, requester_user_id, %AgentSchema{owner_user_id: owner})
       when requester_user_id == owner,
       do: true

  defp requester_in_chat?(chat_id, requester_user_id, _agent) do
    Chat.is_participant?(chat_id, requester_user_id)
  end

  defp redact_id(nil), do: "-"
  defp redact_id(value) when is_binary(value), do: String.slice(value, 0, 8)
  defp redact_id(_value), do: "-"

  defp describe(%{description: description, server: server}) do
    base = description || "MCP tool"
    "#{base} (via #{server.name})"
  end

  defp normalize_schema(schema) when is_map(schema) do
    Map.put_new(schema, "type", "object")
  end

  defp normalize_schema(_schema), do: %{"type" => "object", "properties" => %{}}

  defp error_payload(tool_name, :unknown_tool) do
    %{"ok" => false, "error" => "MCP tool #{tool_name} is not available for this agent."}
  end

  defp error_payload(_tool_name, :agent_not_available) do
    %{"ok" => false, "error" => "This MCP connection is not available in the current chat."}
  end

  defp error_payload(_tool_name, :owner_lookup_required) do
    %{"ok" => false, "error" => "Owner lookup is required for MCP actions."}
  end

  defp error_payload(_tool_name, :not_permitted_here) do
    %{
      "ok" => false,
      "error" =>
        "MCP access is not enabled for this agent in this chat. The agent owner must enable it."
    }
  end

  defp error_payload(_tool_name, :chat_not_attached) do
    %{"ok" => false, "error" => "This agent is not attached to this chat."}
  end

  defp error_payload(_tool_name, :unauthorized) do
    %{"ok" => false, "error" => "The MCP server rejected our credentials. Check the integration secret."}
  end

  defp error_payload(_tool_name, {:http_error, status, detail}) do
    %{"ok" => false, "error" => "MCP server returned HTTP #{status}.", "details" => detail}
  end

  defp error_payload(_tool_name, {:rpc_error, code, message}) do
    %{"ok" => false, "error" => "MCP error #{code}: #{message}"}
  end

  defp error_payload(_tool_name, reason) do
    %{"ok" => false, "error" => "MCP call failed.", "details" => inspect(reason)}
  end
end
