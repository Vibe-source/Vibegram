defmodule VibeWeb.SettingsControllerTest do
  use ExUnit.Case, async: true

  test "settings and device-session routes stay authenticated" do
    routes = VibeWeb.Router.__routes__()
    paths = MapSet.new(routes, &{&1.verb, &1.path})

    assert MapSet.member?(paths, {:get, "/api/settings"})
    assert MapSet.member?(paths, {:patch, "/api/settings/privacy"})
    assert MapSet.member?(paths, {:patch, "/api/settings/notifications"})
    assert MapSet.member?(paths, {:get, "/api/account/sessions"})
    assert MapSet.member?(paths, {:delete, "/api/account/sessions/:id"})
  end
end
