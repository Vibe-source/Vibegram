defmodule VibeAgents.LLM.PromptCacheTest do
  @moduledoc "Anthropic cache breakpoints land on tools, system, and the newest message."

  use ExUnit.Case, async: true

  alias VibeAgents.LLM.Loop
  alias VibeAgents.LLM.Loop.Config

  @ephemeral %{"type" => "ephemeral"}

  defp config(overrides \\ []) do
    defaults = [
      model: "claude-sonnet-5",
      system_prompt: "You are a helpful agent.",
      tools: [
        %{"name" => "search_google", "input_schema" => %{}},
        %{"name" => "read_url", "input_schema" => %{}}
      ],
      execute_tools: fn _, _, _ -> :ok end
    ]

    struct!(Config, Keyword.merge(defaults, overrides))
  end

  setup do
    previous = Application.fetch_env(:vibe_agents, :prompt_cache)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:vibe_agents, :prompt_cache, value)
        :error -> Application.delete_env(:vibe_agents, :prompt_cache)
      end
    end)

    :ok
  end

  test "system becomes a cached text block" do
    payload = Loop.claude_request_payload([%{role: "user", content: "hi"}], config())

    assert [%{"type" => "text", "text" => "You are a helpful agent.", "cache_control" => @ephemeral}] =
             payload["system"]
  end

  test "only the last tool carries a breakpoint" do
    payload = Loop.claude_request_payload([%{role: "user", content: "hi"}], config())

    assert [first, last] = payload["tools"]
    refute Map.has_key?(first, "cache_control")
    assert last["cache_control"] == @ephemeral
  end

  test "a string message becomes a cached text block" do
    payload = Loop.claude_request_payload([%{role: "user", content: "hi"}], config())

    assert [%{content: [%{"type" => "text", "text" => "hi", "cache_control" => @ephemeral}]}] =
             payload["messages"]
  end

  test "only the newest message is marked, and string keys work too" do
    messages = [
      %{"role" => "user", "content" => "first"},
      %{"role" => "assistant", "content" => "reply"},
      %{"role" => "user", "content" => "second"}
    ]

    payload = Loop.claude_request_payload(messages, config())
    [older, middle, newest] = payload["messages"]

    assert older["content"] == "first"
    assert middle["content"] == "reply"
    assert [%{"text" => "second", "cache_control" => @ephemeral}] = newest["content"]
  end

  test "a block-list message marks its last block only" do
    messages = [
      %{
        "role" => "user",
        "content" => [
          %{"type" => "text", "text" => "one"},
          %{"type" => "text", "text" => "two"}
        ]
      }
    ]

    payload = Loop.claude_request_payload(messages, config())
    [%{"content" => [first, last]}] = payload["messages"]

    refute Map.has_key?(first, "cache_control")
    assert last["cache_control"] == @ephemeral
  end

  test "three breakpoints total, under Anthropic's limit of four" do
    messages = [%{role: "user", content: "hi"}]
    payload = Loop.claude_request_payload(messages, config())

    assert count_breakpoints(payload) == 3
  end

  test "the flag off restores the uncached payload shape" do
    Application.put_env(:vibe_agents, :prompt_cache, false)

    messages = [%{role: "user", content: "hi"}]
    payload = Loop.claude_request_payload(messages, config())

    assert payload["system"] == "You are a helpful agent."
    assert payload["messages"] == messages
    assert count_breakpoints(payload) == 0
  end

  test "empty tools and messages are left alone" do
    payload = Loop.claude_request_payload([], config(tools: []))

    assert payload["tools"] == []
    assert payload["messages"] == []
  end

  defp count_breakpoints(term) when is_map(term) do
    own = if Map.get(term, "cache_control") == @ephemeral, do: 1, else: 0
    own + (term |> Map.values() |> Enum.map(&count_breakpoints/1) |> Enum.sum())
  end

  defp count_breakpoints(term) when is_list(term),
    do: term |> Enum.map(&count_breakpoints/1) |> Enum.sum()

  defp count_breakpoints(_term), do: 0
end
