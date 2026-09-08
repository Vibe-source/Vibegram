defmodule VibeContracts.OutputsTest do
  use ExUnit.Case, async: true
  alias VibeContracts.Outputs

  test "text_output/2 builds the frozen text shape" do
    assert Outputs.text_output("hi", %{"a" => 1}) == %{
             "type" => "text",
             "text" => "hi",
             "mediaUrl" => nil,
             "metadata" => %{"a" => 1}
           }

    assert Outputs.text_output("hi") == %{
             "type" => "text",
             "text" => "hi",
             "mediaUrl" => nil,
             "metadata" => %{}
           }
  end

  test "image_output/2 builds the frozen image shape" do
    assert Outputs.image_output("https://x/i.png", %{"w" => 10}) == %{
             "type" => "image",
             "text" => "",
             "mediaUrl" => "https://x/i.png",
             "metadata" => %{"w" => 10}
           }
  end

  test "file_output/4 merges name/mime into metadata" do
    out = Outputs.file_output("https://x/f.pdf", "f.pdf", "application/pdf", %{"extra" => true})
    assert out["type"] == "file"
    assert out["mediaUrl"] == "https://x/f.pdf"
    assert out["metadata"] == %{"name" => "f.pdf", "mime" => "application/pdf", "extra" => true}
  end

  test "question_output/3 builds the waiting_for_user shape with a fallback" do
    questions = [%{"question" => "Which?"}]
    out = Outputs.question_output("req-1", questions, "pick one")

    assert out["type"] == "question"
    assert out["text"] == "pick one"
    assert out["requestId"] == "req-1"
    assert out["status"] == "waiting_for_user"
    assert out["questions"] == questions
    assert out["metadata"]["requestId"] == "req-1"
  end

  test "question_output/3 defaults the fallback text when nil" do
    out = Outputs.question_output("req-1", [], nil)
    assert out["text"] == "Your input is needed to continue."
  end

  test "finalize_batch/2 stamps shared turn/batch ids and per-part index/count/kind" do
    outputs = [Outputs.text_output("a"), Outputs.image_output("https://x/i.png")]
    [first, second] = Outputs.finalize_batch(outputs, base_timestamp: 1000)

    assert first.metadata["agentBatchId"] == second.metadata["agentBatchId"]
    assert first.metadata["agentTurnId"] == second.metadata["agentTurnId"]
    assert first.metadata["agentPartId"] != second.metadata["agentPartId"]
    assert first.metadata["agentPartIndex"] == 0
    assert second.metadata["agentPartIndex"] == 1
    assert first.metadata["agentPartCount"] == 2
    assert second.metadata["agentPartCount"] == 2
    assert first.metadata["agentPartKind"] == "text"
    assert second.metadata["agentPartKind"] == "image"
    assert first.metadata["agentFinalized"] == true
    assert first.timestamp == 1000
    assert second.timestamp == 1001
  end

  test "finalize_batch/2 honors explicit agent_turn_id/agent_batch_id opts" do
    [out] =
      Outputs.finalize_batch([Outputs.text_output("a")],
        agent_turn_id: "turn-1",
        agent_batch_id: "batch-1",
        base_timestamp: 0
      )

    assert out.metadata["agentTurnId"] == "turn-1"
    assert out.metadata["agentBatchId"] == "batch-1"
  end

  test "finalize_batch/2 preserves existing metadata alongside the batch stamp" do
    [out] =
      Outputs.finalize_batch([Outputs.text_output("a", %{"custom" => "keep"})], base_timestamp: 0)

    assert out.metadata["custom"] == "keep"
    assert out.metadata["agentFinalized"] == true
  end

  test "finalize_batch/2 mirrors the reference: accepts atom- or string-typed outputs" do
    [out] = Outputs.finalize_batch([%{type: "music", mediaUrl: "u"}], base_timestamp: 0)
    assert out.metadata["agentPartKind"] == "music"
    assert out[:type] == "music"
  end

  test "finalize_batch/2 of an empty list is an empty list" do
    assert Outputs.finalize_batch([]) == []
  end
end
