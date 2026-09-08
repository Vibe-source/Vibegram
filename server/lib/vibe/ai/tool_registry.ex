defmodule Vibe.AI.ToolRegistry do
  @moduledoc """
  Catalog of agent tools surfaced in agent config and used to validate the per-agent
  `enabled_tools` selection.
  """

  @tools [
    %{
      id: "search_google",
      name: "Web Search",
      description: "Search the web for up-to-date information.",
      category: "research",
      always_on: false,
      testability: "live_readonly"
    },
    %{
      id: "read_url",
      name: "Read Web Page",
      description:
        "Open a search result (or a link the user pasted) and read its actual text, so answers " <>
          "cite pages instead of snippets.",
      category: "research",
      always_on: false,
      testability: "live_readonly"
    },
    %{
      id: "search_music",
      name: "Music Search",
      description:
        "Find tracks by name or resolve SoundCloud/YouTube links into playable audio cards.",
      category: "research",
      always_on: false,
      testability: "live_readonly"
    },
    %{
      id: "analyze_image",
      name: "Image Analysis",
      description: "Describe or inspect an image URL.",
      category: "research",
      always_on: false
    },
    %{
      id: "analyze_document",
      name: "Document Analysis",
      description: "Summarize or inspect a document URL.",
      category: "research",
      always_on: false
    },
    %{
      id: "create_document",
      name: "Create Document",
      description: "Create or replace a spreadsheet or document output.",
      category: "documents",
      always_on: false
    },
    %{
      id: "find_rows",
      name: "Find Rows",
      description: "Search spreadsheet rows before editing or exporting.",
      category: "documents",
      always_on: false
    },
    %{
      id: "edit_rows",
      name: "Edit Rows",
      description: "Update specific spreadsheet rows by index.",
      category: "documents",
      always_on: false
    },
    %{
      id: "delete_rows",
      name: "Delete Rows",
      description: "Delete spreadsheet rows by index.",
      category: "documents",
      always_on: false
    },
    %{
      id: "export_rows",
      name: "Export Rows",
      description: "Export spreadsheet data to PNG or PDF.",
      category: "documents",
      always_on: false
    },
    %{
      id: "delete_document",
      name: "Delete Document",
      description: "Delete the active generated document.",
      category: "documents",
      always_on: false
    },
    %{
      id: "post_to_channel",
      name: "Post to Channel",
      description: "Publish text or rich media to an attached channel as this agent.",
      category: "chat_management",
      always_on: false,
      testability: "dry_run"
    },
    %{
      id: "get_channel_analytics",
      name: "Channel Analytics",
      description: "Read subscriber and message analytics for a managed channel.",
      category: "chat_management",
      always_on: false,
      testability: "dry_run"
    },
    %{
      id: "schedule_channel_post",
      name: "Schedule Channel Post",
      description: "Schedule content to publish to an attached channel as this agent.",
      category: "chat_management",
      always_on: false,
      testability: "dry_run"
    },
    %{
      id: "call_connected_app",
      name: "Connected App & Live Data",
      description:
        "Call a configured connected app/analytics source for live website, business, or admin data and actions.",
      category: "data",
      always_on: false
    },
    %{
      id: "call_mcp_tool",
      name: "MCP Servers",
      description:
        "Use tools from connected MCP servers — their tools appear with full schemas and can return files (PDF, images) that are delivered to the chat.",
      category: "integrations",
      always_on: false,
      testability: "dry_run"
    },
    %{
      id: "list_platform_connections",
      name: "Platform Connections",
      description:
        "List OAuth platform connectors (GitHub, Excel, …) granted to this agent — capability names only, never tokens.",
      category: "integrations",
      always_on: false,
      testability: "dry_run"
    },
    %{
      id: "call_platform",
      name: "Call Platform (GitHub PRs, …)",
      description:
        "Invoke a granted multi-platform action (GitHub PR review/comment/list, Excel later, Slack/Linear later) via server-proxied OAuth.",
      category: "integrations",
      always_on: false
    },
    %{
      id: "query_event_inbox",
      name: "Event Inbox & Analytics",
      description:
        "Query and aggregate the events this agent has received from its connected apps (counts, breakdowns, metric sums, notifications).",
      category: "analytics",
      always_on: true
    },
    %{
      id: "configure_event_inbox",
      name: "Inbox Delivery Settings",
      description:
        "Set how incoming events are delivered: per event or batched summaries (4h / daily).",
      category: "analytics",
      always_on: true,
      testability: "dry_run"
    },
    %{
      id: "get_current_agent_config",
      name: "Current Agent Config",
      description: "Inspect the current owned agent's saved configuration.",
      category: "agent_management",
      always_on: true,
      testability: "dry_run"
    },
    %{
      id: "update_current_agent_config",
      name: "Update Current Agent",
      description: "Update allowlisted fields on the current owned agent.",
      category: "agent_management",
      always_on: true,
      testability: "dry_run"
    },
    %{
      id: "create_chat_space",
      name: "Create Chat Space",
      description: "Create a group or channel for the current agent owner.",
      category: "chat_management",
      always_on: false,
      testability: "dry_run"
    },
    %{
      id: "attach_current_agent_to_chat",
      name: "Attach Current Agent",
      description: "Attach the current agent to an owned group or channel.",
      category: "chat_management",
      always_on: false,
      testability: "dry_run"
    },
    %{
      id: "attach_agent_to_chat",
      name: "Attach Agent",
      description: "Attach a named owned agent to an owned group or channel.",
      category: "chat_management",
      always_on: false,
      testability: "dry_run"
    },
    %{
      id: "check_agent_username",
      name: "Check Agent Username",
      description: "Check whether a public @username is free, with clean alternatives.",
      category: "agent_management",
      always_on: true,
      testability: "live_readonly"
    },
    %{
      id: "inspect_current_agent_tools",
      name: "Inspect Current Agent Tools",
      description: "Show registry, configured, effective, output-mode, and testability state.",
      category: "agent_management",
      always_on: true,
      testability: "dry_run"
    },
    %{
      id: "test_current_agent_tool",
      name: "Test Current Agent Tool",
      description: "Run a bounded read-only tool check or validate a dry-run capability.",
      category: "agent_management",
      always_on: true,
      testability: "dry_run"
    },
    %{
      id: "ask_user",
      name: "Ask User",
      description: "Finish the turn with normalized questions for the user.",
      category: "interaction",
      always_on: true,
      testability: "dry_run"
    },
    # Isolated-runtime only:
    %{
      id: "computer_run",
      name: "Computer",
      description:
        "The agent gets its own Linux computer: shell, python, node, git, file read/write/edit, " <>
          "and a real Chromium browser. Forces the isolated runtime.",
      category: "computer",
      always_on: false,
      testability: "dry_run"
    },
    %{
      id: "browser_open",
      name: "Browser",
      description:
        "Browser only: open pages, read them, click and type, screenshot. Sessions and logins " <>
          "persist. Forces the isolated runtime.",
      category: "computer",
      always_on: false,
      testability: "dry_run"
    }
  ]

  @tools Enum.map(@tools, fn tool -> Map.put_new(tool, :testability, "dry_run") end)

  @doc "Full catalog including always-on tools (for display/config)."
  def tools, do: @tools

  @doc "Tools the user can toggle per agent (excludes always-on runtime tools)."
  def toggleable_tools, do: Enum.reject(@tools, & &1.always_on)

  @doc "Tools belonging to a category, e.g. \"analytics\" or \"documents\"."
  def tools_in_category(category) when is_binary(category) do
    Enum.filter(@tools, &(&1.category == category))
  end

  @doc "All known tool ids (toggleable + always-on)."
  def tool_ids, do: Enum.map(@tools, & &1.id)

  @doc "Looks up one registry entry by id."
  def get(tool_id) when is_binary(tool_id), do: Enum.find(@tools, &(&1.id == tool_id))
  def get(_tool_id), do: nil

  @doc "Toggleable tool ids only."
  def toggleable_tool_ids, do: Enum.map(toggleable_tools(), & &1.id)

  @doc "Default selection for a new agent: every toggleable tool except the opt-in computer set."
  def default_tool_ids do
    Enum.reject(toggleable_tools(), &(&1.category == "computer")) |> Enum.map(& &1.id)
  end
end
