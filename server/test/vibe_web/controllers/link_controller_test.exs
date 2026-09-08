defmodule VibeWeb.LinkControllerTest do
  use ExUnit.Case, async: true

  test "share-link routes are registered in the order the resolver depends on" do
    routes = VibeWeb.Router.__routes__()
    paths = MapSet.new(routes, &{&1.verb, &1.path})

    assert MapSet.member?(paths, {:get, "/api/links/resolve"})
    assert MapSet.member?(paths, {:get, "/.well-known/apple-app-site-association"})
    assert MapSet.member?(paths, {:get, "/:handle"})

    index = fn path -> Enum.find_index(routes, &(&1.path == path)) end

    assert index.("/r/:slug") < index.("/:handle")
    assert index.("/j/:token") < index.("/:handle")
    assert index.("/api/links/resolve") < index.("/:handle")
    assert index.("/:handle") < index.("/*path")
  end

  test "each share-link path lands on the action that owns it" do
    routes = VibeWeb.Router.__routes__()
    route = fn path -> Enum.find(routes, &(&1.path == path)) end

    assert %{plug: VibeWeb.LinkController, plug_opts: :preview} = route.("/:handle")
    assert %{plug: VibeWeb.LinkController, plug_opts: :resolve} = route.("/api/links/resolve")

    assert %{plug: VibeWeb.LinkController, plug_opts: :aasa} =
             route.("/.well-known/apple-app-site-association")
  end
end
