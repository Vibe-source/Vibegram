defmodule Vibe.AI.Tools.Platform do
  @moduledoc """
  Agent tool surface for multi-platform connectors (GitHub PRs, Excel later, …).
  """

  alias Vibe.Agent, as: AgentSchema
  alias Vibe.Agents
  alias Vibe.Platforms

  def list_connections(input, agent_id, requester_user_id) do
    with {:ok, owner_id, grantee_type, grantee_id} <-
           resolve_grantee(agent_id, requester_user_id, input) do
      items = Platforms.list_usable_for_grantee(owner_id, grantee_type, grantee_id)

      %{
        "ok" => true,
        "items" => items,
        "summary" =>
          if(items == [],
            do: "No platform connectors granted to this agent.",
            else: "#{length(items)} connector(s) available."
          )
      }
    else
      {:error, reason} -> error_payload(reason)
    end
  end

  def invoke(input, agent_id, requester_user_id) do
    with {:ok, owner_id, grantee_type, grantee_id} <-
           resolve_grantee(agent_id, requester_user_id, input),
         {:ok, result} <- Platforms.invoke(owner_id, grantee_type, grantee_id, input) do
      result
    else
      {:error, reason} -> error_payload(reason)
    end
  end

  def prompt_guidance(%AgentSchema{} = agent) do
    Platforms.prompt_guidance(agent.owner_user_id, "agent", agent.id)
  end

  def prompt_guidance(owner_user_id, grantee_type, grantee_id)
      when is_binary(owner_user_id) do
    Platforms.prompt_guidance(owner_user_id, grantee_type, grantee_id)
  end

  defp resolve_grantee(agent_id, requester_user_id, input)
       when is_binary(agent_id) and is_binary(requester_user_id) do
    case Agents.get_agent(agent_id, requester_user_id) do
      %AgentSchema{} = agent ->
        {:ok, agent.owner_user_id, "agent", agent.id}

      nil ->
        bridge_id = normalize_bridge(input["grantee_id"] || input["granteeId"] || agent_id)

        if bridge_id do
          {:ok, requester_user_id, "bridge_agent", bridge_id}
        else
          {:error, :agent_not_available}
        end
    end
  end

  defp resolve_grantee(_agent_id, requester_user_id, input)
       when is_binary(requester_user_id) do
    bridge_id = normalize_bridge(input["grantee_id"] || input["granteeId"] || "claude")

    if bridge_id do
      {:ok, requester_user_id, "bridge_agent", bridge_id}
    else
      {:error, :owner_lookup_required}
    end
  end

  defp resolve_grantee(_, _, _), do: {:error, :owner_lookup_required}

  defp normalize_bridge(id) when is_binary(id) do
    case String.downcase(String.trim(id)) do
      id when id in ~w[claude codex grok agy vibe] -> id
      _ -> nil
    end
  end

  defp normalize_bridge(_), do: nil

  defp error_payload(:no_grant) do
    %{
      "ok" => false,
      "error" => "no_grant",
      "message" =>
        "No platform connection is granted to this agent. Ask the user to connect GitHub (or another provider) in Settings → Connected Apps and enable agent access."
    }
  end

  defp error_payload(:agent_not_available) do
    %{"ok" => false, "error" => "agent_not_available", "message" => "Agent not found for owner."}
  end

  defp error_payload({:capability_not_allowed, allowed}) do
    %{
      "ok" => false,
      "error" => "capability_not_allowed",
      "message" => "Action not allowed for this grant.",
      "allowed" => allowed
    }
  end

  defp error_payload(reason) do
    %{
      "ok" => false,
      "error" => "platform_error",
      "message" => safe_message(reason)
    }
  end

  defp safe_message(reason) when is_atom(reason), do: to_string(reason)
  defp safe_message(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp safe_message(reason), do: String.slice(inspect(reason), 0, 200)
end
