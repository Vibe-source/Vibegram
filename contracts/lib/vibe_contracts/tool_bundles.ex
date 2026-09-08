defmodule VibeContracts.ToolBundles do
  @moduledoc """
  One table mapping a coarse capability id stored on an agent to the concrete tool names it
  grants. Server (capability gating) and runtime (tool specs, prompt) both read it, so a new
  tool reaches every already-configured agent by being added to a family here — no migration.
  """

  @computer ~w(computer_run computer_read_file computer_write_file computer_edit_file computer_list_files)
  @browser ~w(browser_open browser_read_page browser_act browser_screenshot)
  @research ~w(search_google read_url)
  @team ~w(handoff_to_agent)

  # A computer is a machine with a browser on it:
  @bundles %{
    "computer" => @computer ++ @browser,
    "browser" => @browser,
    "research" => @research,
    "team" => @team
  }

  # Coarse ids the agent-config UI has stored historically.
  @aliases %{"computer_run" => "computer", "browser_open" => "browser"}

  def bundles, do: @bundles
  def bundle_ids, do: Map.keys(@bundles)
  def computer_tools, do: @computer
  def browser_tools, do: @browser
  def research_tools, do: @research
  def team_tools, do: @team

  @doc "Expands bundle names and coarse aliases into the concrete tool ids they grant."
  def expand(enabled_tools) do
    enabled_tools
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.flat_map(fn id ->
      case @bundles[Map.get(@aliases, id, id)] do
        nil -> [id]
        members -> members
      end
    end)
    |> Enum.uniq()
  end

  @doc "True when any tool in the family is reachable from these enabled tools."
  def computer?(enabled_tools), do: any_of?(enabled_tools, @computer)
  def browser?(enabled_tools), do: any_of?(enabled_tools, @browser)
  def research?(enabled_tools), do: any_of?(enabled_tools, @research)
  def team?(enabled_tools), do: any_of?(enabled_tools, @team)

  @doc "True when the agent needs a sandbox at all — the isolated runtime is then mandatory."
  def sandbox?(enabled_tools), do: computer?(enabled_tools) or browser?(enabled_tools)

  @doc "Capability map handed to the isolated runtime with every run."
  def capabilities(enabled_tools) do
    expanded = expand(enabled_tools)

    %{
      "computer" => any_of?(expanded, @computer),
      "browser" => any_of?(expanded, @browser),
      "network" => if(sandbox?(expanded), do: "allowlist", else: "none")
    }
  end

  defp any_of?(enabled_tools, family) do
    expanded = expand(enabled_tools)
    Enum.any?(family, &(&1 in expanded))
  end
end
