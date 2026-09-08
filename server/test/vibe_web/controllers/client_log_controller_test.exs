defmodule VibeWeb.ClientLogControllerTest do
  # Not async: an :info report is only observable with the global Logger level lowered.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias VibeWeb.ClientLogController

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  defp conn_for(params) do
    :post
    |> conn("/api/client-logs", params)
    |> Plug.Conn.assign(:current_user, %{id: "user-1"})
    |> Phoenix.Controller.accepts(["json"])
  end

  # Most of these land at :info, which the configured level would otherwise swallow.
  defp capture(params) do
    capture_log([level: :debug], fn -> ClientLogController.create(conn_for(params), params) end)
  end

  test "the ingest route is registered on the controller that owns it" do
    route = Enum.find(VibeWeb.Router.__routes__(), &(&1.path == "/api/client-logs"))

    assert %{plug: ClientLogController, plug_opts: :create, verb: :post} = route
  end

  test "a client error report reaches the journal tagged for @monitor" do
    params = %{
      "app" => %{"platform" => "ios", "build" => "2026.9.1"},
      "events" => [
        %{"level" => "fatal", "tag" => "crypto", "message" => "hybrid open failed epoch=41"}
      ]
    }

    log = capture(params)

    assert log =~ "[ClientLog]"
    assert log =~ "user=user-1"
    assert log =~ "platform=ios"
    assert log =~ "build=2026.9.1"
    assert log =~ "level=fatal"
    assert log =~ "tag=crypto"
    assert log =~ "hybrid open failed"
  end

  test "a report is capped, and an unknown level is not taken on trust" do
    events = for i <- 1..500, do: %{"level" => "nonsense", "message" => "line #{i}"}
    params = %{"events" => events}

    log = capture(params)

    assert length(String.split(log, "[ClientLog]")) - 1 == 200
    assert log =~ "level=info"
    refute log =~ "level=nonsense"
  end

  test "a field cannot forge extra key=value pairs into a log line" do
    params = %{
      "app" => %{"platform" => "ios level=fatal user=admin"},
      "events" => [%{"level" => "info", "message" => "x"}]
    }

    log = capture(params)

    assert log =~ "platform=ios_level_fatal_user_admin"
    refute log =~ "level=fatal"
  end

  test "a body with no usable events is accepted without logging one" do
    for params <- [%{}, %{"events" => []}, %{"events" => "not-a-list"}] do
      refute capture(params) =~ "[ClientLog]"
    end
  end
end
