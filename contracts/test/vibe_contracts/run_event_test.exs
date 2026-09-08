defmodule VibeContracts.RunEventTest do
  use ExUnit.Case, async: true
  alias VibeContracts.RunEvent

  @base %{
    "runId" => "r1",
    "agentId" => "a1",
    "agentUserId" => "au1",
    "chatId" => "c1",
    "seq" => 0,
    "kind" => "run.text.delta",
    "payload" => %{"text" => "hi"}
  }

  test "kinds/0 lists all 18 frozen kinds" do
    assert length(RunEvent.kinds()) == 18
    assert "run.tool.completed" in RunEvent.kinds()
    assert "run.ask" in RunEvent.kinds()
    assert "run.computer.state" in RunEvent.kinds()
    assert "run.computer.control" in RunEvent.kinds()
  end

  test "terminal?/1 is true only for cancelled/completed/failed" do
    assert RunEvent.terminal?("run.completed")
    assert RunEvent.terminal?("run.failed")
    assert RunEvent.terminal?("run.cancelled")
    refute RunEvent.terminal?("run.started")
    refute RunEvent.terminal?("run.text.delta")
  end

  test "payload_schema/1 returns the required keys per kind, [] for unknown kinds" do
    assert RunEvent.payload_schema("run.text.delta") == ["text"]

    assert RunEvent.payload_schema("run.approval.resolved") == [
             "decisionId",
             "outcome",
             "actorUserId"
           ]

    assert RunEvent.payload_schema("run.nonsense") == []
  end

  test "new/1 fills contract and ts defaults when the caller omits them" do
    assert {:ok, event} =
             RunEvent.new(%{@base | "kind" => "run.cancelled", "payload" => %{"reason" => "x"}})

    assert event["contract"] == "vibe.agentic.v1"
    assert is_integer(event["ts"])
    assert event["ts"] > 0
  end

  test "new/1 accepts a minimal event and normalizes to string keys" do
    assert {:ok, event} = RunEvent.new(@base)

    assert event == %{
             "contract" => "vibe.agentic.v1",
             "runId" => "r1",
             "agentId" => "a1",
             "agentUserId" => "au1",
             "chatId" => "c1",
             "seq" => 0,
             "ts" => event["ts"],
             "kind" => "run.text.delta",
             "payload" => %{"text" => "hi"}
           }
  end

  test "new/1 and validate/1 accept atom keys and normalize the result to strings" do
    atom_attrs = %{
      runId: "r1",
      agentId: "a1",
      agentUserId: "au1",
      chatId: "c1",
      seq: 2,
      kind: "run.completed",
      payload: %{summary: "done", usage: %{}, costCents: 10}
    }

    assert {:ok, event} = RunEvent.new(atom_attrs)
    assert event["runId"] == "r1"
    assert event["payload"] == %{"summary" => "done", "usage" => %{}, "costCents" => 10}
  end

  test "new/1 rejects an unknown kind" do
    assert {:error, :invalid_kind} = RunEvent.new(%{@base | "kind" => "run.bogus"})
  end

  test "new/1 rejects a negative or non-integer seq" do
    assert {:error, :invalid_seq} = RunEvent.new(%{@base | "seq" => -1})
    assert {:error, :invalid_seq} = RunEvent.new(%{@base | "seq" => "0"})
  end

  test "new/1 rejects empty or missing id fields" do
    assert {:error, :invalid_run_id} = RunEvent.new(Map.put(@base, "runId", ""))
    assert {:error, :invalid_agent_id} = RunEvent.new(Map.delete(@base, "agentId"))
    assert {:error, :invalid_chat_id} = RunEvent.new(Map.put(@base, "chatId", 123))
  end

  test "new/1 and validate/1 reject a payload missing required keys for its kind" do
    incomplete = %{@base | "kind" => "run.completed", "payload" => %{"summary" => "s"}}
    assert {:error, :invalid_payload} = RunEvent.new(incomplete)
    assert {:error, :invalid_payload} = RunEvent.validate(Map.put(incomplete, "ts", 1))
  end

  test "validate/1 requires ts to already be present (unlike new/1, it does not default it)" do
    assert {:error, :invalid_ts} = RunEvent.validate(@base)
    assert {:ok, event} = RunEvent.validate(Map.put(@base, "ts", 42))
    assert event["ts"] == 42
  end

  test "validate/1 does not enforce a fixed contract value, only defaults it when absent" do
    assert {:ok, event} =
             RunEvent.validate(Map.merge(@base, %{"ts" => 1, "contract" => "something.else"}))

    assert event["contract"] == "something.else"
  end
end
