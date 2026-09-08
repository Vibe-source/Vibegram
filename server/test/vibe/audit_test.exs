defmodule Vibe.AuditTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Vibe.Audit
  alias Vibe.Repo
  alias Vibe.Schemas.AuditEvent

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "records an event with request context and never raises" do
    conn = Plug.Test.conn(:post, "/api/login") |> Plug.Conn.put_req_header("user-agent", "VibeTest/1.0")
    assert :ok = Audit.record(conn, "login.failure", metadata: %{username: "someone"})

    event = Repo.one!(from(e in AuditEvent, where: e.action == "login.failure", limit: 1))
    assert event.user_agent == "VibeTest/1.0"
    assert event.ip == "127.0.0.1"
    assert event.metadata["username"] == "someone"
  end

  test "accepts a nil conn and prunes old rows" do
    assert :ok = Audit.record(nil, "device.revoke", target_id: "dev-1")
    assert 0 == Audit.prune(1)
  end

  test "an invalid action never breaks the caller" do
    assert :ok = Audit.record(nil, nil)
  end
end
