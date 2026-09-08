defmodule Vibe.AgentEventStreamTest do
  @moduledoc """
  Pure-logic tests for `message.stream` (no DB).
  """
  use ExUnit.Case, async: true

  alias Vibe.AI.AgentEventRuntime

  # ── normalize_stream_params/1 ──────────────────────────────────────────────

  describe "normalize_stream_params/1" do
    test "accepts camelCase stream frame fields" do
      assert {:ok, frame} =
               AgentEventRuntime.normalize_stream_params(%{
                 "streamId" => "s-1",
                 "seq" => 3,
                 "text" => "Hello world",
                 "done" => false,
                 "destinationChatId" => "chat-abc"
               })

      assert frame.stream_id == "s-1"
      assert frame.seq == 3
      assert frame.text == "Hello world"
      assert frame.done == false
      assert frame.destination_chat_id == "chat-abc"
      assert frame.content == nil
    end

    test "accepts snake_case aliases and content envelope" do
      content = %{
        "contract" => "vibe.content.v1",
        "fallbackText" => "hi",
        "parts" => [%{"kind" => "text", "text" => "hi"}]
      }

      assert {:ok, frame} =
               AgentEventRuntime.normalize_stream_params(%{
                 "stream_id" => "s-2",
                 "seq" => "7",
                 "message" => "from message key",
                 "done" => true,
                 "destination_chat_id" => "chat-xyz",
                 "content" => content
               })

      assert frame.stream_id == "s-2"
      assert frame.seq == 7
      assert frame.text == "from message key"
      assert frame.done == true
      assert frame.content == content
    end

    test "requires streamId and seq" do
      assert {:error, :missing_stream_id} =
               AgentEventRuntime.normalize_stream_params(%{"seq" => 1, "text" => "x"})

      assert {:error, :missing_seq} =
               AgentEventRuntime.normalize_stream_params(%{"streamId" => "s", "text" => "x"})
    end

    test "empty text is allowed" do
      assert {:ok, frame} =
               AgentEventRuntime.normalize_stream_params(%{
                 "streamId" => "s",
                 "seq" => 0,
                 "text" => ""
               })

      assert frame.text == ""
    end

    test "rejects oversized stream frames before stream state is touched" do
      assert {:error, :stream_payload_too_large} =
               AgentEventRuntime.normalize_stream_params(%{
                 "streamId" => "s",
                 "seq" => 1,
                 "text" => String.duplicate("x", 300_000)
               })
    end
  end

  # ── stream_frame_decision/2 ────────────────────────────────────────────────

  describe "stream_frame_decision/2 — seq ordering + ignore-stale" do
    defp frame(seq, done \\ false, text \\ "t") do
      %{
        stream_id: "sid",
        seq: seq,
        text: text,
        content: nil,
        done: done,
        destination_chat_id: "chat"
      }
    end

    test "nil state + not done => create" do
      assert {:create, %{last_seq: 1, done: false, message_id: nil}, _} =
               AgentEventRuntime.stream_frame_decision(nil, frame(1, false))
    end

    test "nil state + done => create_finalize (done-only unknown streamId)" do
      assert {:create_finalize, %{last_seq: 9, done: true, message_id: nil}, f} =
               AgentEventRuntime.stream_frame_decision(nil, frame(9, true, "final"))

      assert f.done == true
      assert f.text == "final"
    end

    test "later seq => update and advance last_seq" do
      state = %{message_id: "m1", last_seq: 2, done: false}

      assert {:update, %{message_id: "m1", last_seq: 5, done: false}, _} =
               AgentEventRuntime.stream_frame_decision(state, frame(5, false))
    end

    test "seq <= last_seq is ignored (stale / idempotent)" do
      state = %{message_id: "m1", last_seq: 5, done: false}

      assert {:ignore, :stale_seq} =
               AgentEventRuntime.stream_frame_decision(state, frame(5, false))

      assert {:ignore, :stale_seq} =
               AgentEventRuntime.stream_frame_decision(state, frame(3, false))

      assert {:ignore, :stale_seq} =
               AgentEventRuntime.stream_frame_decision(state, frame(4, true))
    end

    test "higher seq with done => finalize" do
      state = %{message_id: "m1", last_seq: 2, done: false}

      assert {:finalize, %{message_id: "m1", last_seq: 10, done: true}, _} =
               AgentEventRuntime.stream_frame_decision(state, frame(10, true))
    end

    test "after done, further frames are ignored" do
      state = %{message_id: "m1", last_seq: 10, done: true}

      assert {:ignore, :stream_done} =
               AgentEventRuntime.stream_frame_decision(state, frame(11, false))

      assert {:ignore, :stream_done} =
               AgentEventRuntime.stream_frame_decision(state, frame(12, true))
    end

    test "monotonic seq progression over multiple frames" do
      state = nil

      {:create, state, _} = AgentEventRuntime.stream_frame_decision(state, frame(1))
      state = %{state | message_id: "m1"}

      {:update, state, _} = AgentEventRuntime.stream_frame_decision(state, frame(2))
      assert state.last_seq == 2

      assert {:ignore, :stale_seq} =
               AgentEventRuntime.stream_frame_decision(state, frame(2))

      {:update, state, _} = AgentEventRuntime.stream_frame_decision(state, frame(4))
      assert state.last_seq == 4

      {:finalize, state, _} = AgentEventRuntime.stream_frame_decision(state, frame(5, true))
      assert state.done == true
      assert state.last_seq == 5
    end
  end

  # ── finalize_stream_content/2 ──────────────────────────────────────────────

  describe "finalize_stream_content/2" do
    test "nil content keeps text" do
      assert {:ok, "hello", nil} = AgentEventRuntime.finalize_stream_content("hello", nil)
    end

    test "valid content: envelope text wins via to_message_attrs" do
      content = %{
        "contract" => "vibe.content.v1",
        "fallbackText" => "fallback only",
        "parts" => [
          %{"kind" => "text", "text" => "Part A"},
          %{"kind" => "text", "text" => "Part B"}
        ]
      }

      assert {:ok, body, normalized} =
               AgentEventRuntime.finalize_stream_content("stream-text-ignored", content)

      assert body == "Part A\n\nPart B"
      assert normalized["contract"] == "vibe.content.v1"
      assert is_list(normalized["parts"])
    end

    test "valid content with only status parts uses fallbackText" do
      content = %{
        "contract" => "vibe.content.v1",
        "fallbackText" => "status summary",
        "parts" => [%{"kind" => "status", "text" => "thinking"}]
      }

      assert {:ok, "status summary", _} =
               AgentEventRuntime.finalize_stream_content("stream", content)
    end

    test "invalid content on done: keeps text and returns invoke-shaped error" do
      bad = %{
        "contract" => "nope.v9",
        "fallbackText" => "x",
        "parts" => []
      }

      assert {:error, {:invalid_content, reason}, "keep me"} =
               AgentEventRuntime.finalize_stream_content("keep me", bad)

      assert reason == {:invalid_content, :unknown_contract} or is_atom(reason)
    end

    test "malformed non-map content is ignored (text only)" do
      assert {:ok, "plain", nil} =
               AgentEventRuntime.finalize_stream_content("plain", "not-a-map")
    end

    test "missing fallbackText is invalid content, text preserved" do
      bad = %{
        "contract" => "vibe.content.v1",
        "parts" => [%{"kind" => "text", "text" => "hi"}]
      }

      assert {:error, {:invalid_content, _reason}, "acc"} =
               AgentEventRuntime.finalize_stream_content("acc", bad)
    end
  end
end
