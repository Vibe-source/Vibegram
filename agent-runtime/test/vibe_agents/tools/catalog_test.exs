defmodule VibeAgents.Tools.CatalogTest do
  use ExUnit.Case, async: true

  alias VibeAgents.Tools.Catalog

  defp names(specs), do: specs |> Enum.map(& &1["name"]) |> Enum.sort()

  test "always-on tools are present even when nothing is enabled" do
    assert names(Catalog.specs(%{"enabledTools" => []}, %{})) == ~w(ask_user recall remember request_approval)
  end

  test "computer and browser tools require their capability" do
    profile = %{"enabledTools" => ["computer_run", "browser_open", "search_google"]}

    assert "computer_run" not in names(Catalog.specs(profile, %{"computer" => false, "browser" => false}))
    assert "browser_open" not in names(Catalog.specs(profile, %{"computer" => false, "browser" => false}))
    assert "search_google" in names(Catalog.specs(profile, %{}))

    with_caps = names(Catalog.specs(profile, %{"computer" => true, "browser" => true}))
    assert "computer_run" in with_caps and "browser_open" in with_caps
  end

  test "unknown tool names are dropped and every spec has a schema" do
    specs = Catalog.specs(%{"enabledTools" => ["search_google", "nonsense_tool"]}, %{})
    refute "nonsense_tool" in names(specs)
    assert Enum.all?(specs, &is_map(&1["input_schema"]))
  end
end
