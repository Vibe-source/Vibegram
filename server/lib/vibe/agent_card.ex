defmodule Vibe.AgentCard do
  @moduledoc """
  Builds the public A2A-compatible agent card for a Vibe standalone agent.
  """

  alias Vibe.Agent
  alias Vibe.Repo

  @doc """
  Build the frozen A2A-compatible agent card map for `agent`.
  """
  @spec build(struct(), String.t()) :: map()
  def build(%Agent{} = agent, base_url) when is_binary(base_url) do
    agent = Repo.preload(agent, [:agent_user, :owner])
    identifier = identifier(agent)
    origin = base_url |> String.trim() |> String.trim_trailing("/")

    %{
      "protocolVersion" => "0.3.0",
      "kind" => "vibe.agent-card",
      "identifier" => identifier,
      "name" => agent.display_name || "",
      "description" => description(agent),
      "url" => "#{origin}/api/agents/#{identifier}/invoke",
      "eventsUrl" => "#{origin}/api/agents/#{identifier}/events",
      "provider" => %{
        "organization" => owner_organization(agent.owner),
        "url" => nil
      },
      "version" => "1",
      "capabilities" => %{
        "streaming" => true,
        "pushNotifications" => true,
        "events" => agent.event_types_enabled || [],
        "contentContract" => Vibe.ProviderContent.capabilities(),
        "realtimeVoice" => Vibe.ProviderContent.realtime_voice_capability(agent)
      },
      "defaultInputModes" => ["text"],
      "defaultOutputModes" => agent.output_modes || [],
      "securitySchemes" => security_schemes(agent),
      "skills" => skills(agent.enabled_tools),
      "status" => agent.status || ""
    }
  end

  defp identifier(%Agent{agent_user: %{username: username}}) when is_binary(username), do: username
  defp identifier(_agent), do: ""

  defp description(%Agent{} = agent) do
    present(agent.persona) || present(agent.welcome_message) || ""
  end

  defp present(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present(_), do: nil

  defp owner_organization(%{name: name} = owner) do
    present(name) || present(Map.get(owner, :username)) || ""
  end

  defp owner_organization(_), do: ""

  defp security_schemes(_agent) do
    %{
      "agentSecret" => %{
        "type" => "apiKey",
        "in" => "header",
        "name" => "X-Vibe-Agent-Secret",
        "description" =>
          "Shared agent webhook secret. Required on POST /api/agents/:identifier/invoke. " <>
            "Also accepted on POST /api/agents/:identifier/events. " <>
            "Send the full secret value in this header; do not put it in the body."
      },
      "integrationSecret" => %{
        "type" => "apiKey",
        "in" => "header",
        "name" => "X-Vibe-Integration-Secret",
        "description" =>
          "Optional per-integration secret accepted on POST /api/agents/:identifier/events only " <>
            "(alternative to X-Vibe-Agent-Secret)."
      }
    }
  end

  defp skills(tools) when is_list(tools) do
    tools
    |> Enum.filter(&is_binary/1)
    |> Enum.map(fn tool ->
      %{
        "id" => tool,
        "name" => tool,
        "description" => "",
        "tags" => []
      }
    end)
  end

  defp skills(_), do: []
end
