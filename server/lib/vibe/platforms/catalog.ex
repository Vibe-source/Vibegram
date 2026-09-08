defmodule Vibe.Platforms.Catalog do
  @moduledoc """
  Multi-platform connector catalog.
  """

  alias Vibe.Platforms.Providers.GitHub

  @providers %{
    "github" => GitHub
  }

  @stub_providers [
    %{
      id: "microsoft_excel",
      name: "Microsoft Excel",
      description:
        "Read and update workbooks via Microsoft Graph — spreadsheets as agent memory for ops and finance.",
      icon: "tablecells",
      category: "productivity",
      status: "coming_soon",
      capabilities: [
        %{id: "list_workbooks", name: "List workbooks", description: "List recent Excel files."},
        %{id: "read_range", name: "Read range", description: "Read a worksheet range."},
        %{id: "write_range", name: "Write range", description: "Update cells in a range."}
      ]
    },
    %{
      id: "slack",
      name: "Slack",
      description: "Search channels, post updates, and pull decision context into agent runs.",
      icon: "number",
      category: "collaboration",
      status: "coming_soon",
      capabilities: [
        %{id: "search_messages", name: "Search messages", description: "Search workspace history."},
        %{id: "post_message", name: "Post message", description: "Post to a channel."}
      ]
    },
    %{
      id: "linear",
      name: "Linear",
      description: "Issues, cycles, and PR↔ticket links for engineering agents.",
      icon: "line.3.horizontal",
      category: "engineering",
      status: "coming_soon",
      capabilities: [
        %{id: "list_issues", name: "List issues", description: "List assigned issues."},
        %{id: "create_issue", name: "Create issue", description: "Create a Linear issue."},
        %{id: "update_issue", name: "Update issue", description: "Update status or fields."}
      ]
    },
    %{
      id: "google_calendar",
      name: "Google Calendar",
      description: "Read schedules and create events for proactive agent triggers.",
      icon: "calendar",
      category: "productivity",
      status: "coming_soon",
      capabilities: [
        %{id: "list_events", name: "List events", description: "Upcoming events."},
        %{id: "create_event", name: "Create event", description: "Create a calendar event."}
      ]
    }
  ]

  def provider_module(id) when is_binary(id), do: Map.get(@providers, id)
  def provider_module(_), do: nil

  def live_providers, do: Map.keys(@providers)

  def get(id) when is_binary(id) do
    case provider_module(id) do
      nil ->
        Enum.find(@stub_providers, &(&1.id == id))

      mod ->
        live_entry(mod)
    end
  end

  def list do
    live =
      @providers
      |> Map.values()
      |> Enum.map(&live_entry/1)

    live ++ @stub_providers
  end

  def capabilities(provider_id) do
    case get(provider_id) do
      %{capabilities: caps} when is_list(caps) -> caps
      _ -> []
    end
  end

  def capability_ids(provider_id) do
    provider_id
    |> capabilities()
    |> Enum.map(& &1.id)
  end

  def oauth_configured?(provider_id) do
    case provider_module(provider_id) do
      nil -> false
      mod -> mod.oauth_configured?()
    end
  end

  defp live_entry(mod) do
    %{
      id: mod.id(),
      name: mod.name(),
      description: mod.description(),
      icon: mod.icon(),
      category: mod.category(),
      status: if(mod.oauth_configured?(), do: "ready", else: "needs_config"),
      scopes: mod.default_scopes(),
      capabilities: mod.capabilities()
    }
  end
end
