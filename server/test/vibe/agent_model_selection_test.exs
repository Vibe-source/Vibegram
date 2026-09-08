defmodule Vibe.AI.AgentModelSelectionTest do
  use ExUnit.Case, async: true

  alias Vibe.AI.AgentRuntime
  alias Vibe.AI.AgentRuntime.Config
  alias Vibe.AI.ModelRegistry
  alias VibeWeb.AgentChannel

  test "publishes the supported providers and defaults new agents to Sonnet 5" do
    assert ModelRegistry.default_selection() == %{
             provider: "anthropic",
             model_id: "claude-sonnet-5",
             thinking_level: "medium"
           }

    payload = ModelRegistry.public_payload()

    assert payload.default == %{
             provider: "anthropic",
             modelId: "claude-sonnet-5",
             thinkingLevel: "medium"
           }

    assert Enum.map(payload.providers, & &1.id) == ["anthropic", "openai"]

    assert Enum.map(Enum.at(payload.providers, 0).models, & &1.id) == [
             "claude-fable-5",
             "claude-opus-4-8",
             "claude-sonnet-5",
             "claude-haiku-4-5-20251001"
           ]

    assert Enum.map(Enum.at(payload.providers, 1).models, & &1.id) == [
             "gpt-5.6-sol",
             "gpt-5.6-terra",
             "gpt-5.6-luna"
           ]

    models = payload.providers |> Enum.flat_map(& &1.models) |> Map.new(&{&1.id, &1})

    assert models["claude-sonnet-5"].thinkingLevels == [
             "low",
             "medium",
             "high",
             "xhigh",
             "max"
           ]

    assert models["claude-sonnet-5"].defaultThinkingLevel == "medium"
    assert models["claude-haiku-4-5-20251001"].thinkingLevels == ["medium"]
    assert models["gpt-5.6-terra"].thinkingLevels == ["low", "medium", "high", "xhigh"]
    assert models["gpt-5.6-luna"].thinkingLevels == ["low", "medium", "high"]
  end

  test "resolves complete and partial selections without accepting mismatched pairs" do
    assert {:ok, %{provider: "openai", model_id: "gpt-5.6-sol", thinking_level: "medium"}} =
             ModelRegistry.resolve_selection(%{"model_id" => "gpt-5.6-sol"})

    assert {:ok, %{provider: "openai", model_id: "gpt-5.6-luna", thinking_level: "medium"}} =
             ModelRegistry.resolve_selection(%{"modelProvider" => "openai"})

    assert {:ok,
            %{
              provider: "anthropic",
              model_id: "claude-opus-4-8",
              thinking_level: "xhigh"
            }} =
             ModelRegistry.resolve_selection(%{
               model_provider: "anthropic",
               model_id: "claude-opus-4-8",
               thinkingLevel: "xhigh"
             })

    assert {:error, :invalid_model_selection} =
             ModelRegistry.resolve_selection(%{
               "model_provider" => "anthropic",
               "model_id" => "gpt-5.6-terra"
             })

    assert {:error, :invalid_model_id} =
             ModelRegistry.resolve_selection(%{"model_id" => "not-a-model"})

    assert {:error, :invalid_thinking_level} =
             ModelRegistry.resolve_selection(%{
               "model_id" => "gpt-5.6-luna",
               "thinking_level" => "xhigh"
             })

    assert {:error, :invalid_thinking_level} =
             ModelRegistry.resolve_selection(%{
               "model_id" => "claude-sonnet-5",
               "thinkingLevel" => "unlimited"
             })
  end

  test "keeps an existing agent selection when the update omits model fields" do
    assert {:ok,
            %{
              provider: "anthropic",
              model_id: "claude-haiku-4-5-20251001",
              thinking_level: "medium"
            }} =
             ModelRegistry.resolve_selection(
               %{"display_name" => "Renamed"},
               %{provider: "anthropic", model_id: "claude-haiku-4-5-20251001"}
             )
  end

  test "agent channel rejects invalid thinking before entering message handling" do
    socket = %Phoenix.Socket{}

    assert {:reply, {:error, %{reason: "invalid_thinking_level"}}, ^socket} =
             AgentChannel.handle_in(
               "message",
               %{
                 "text" => "Hello",
                 "model_id" => "gpt-5.6-luna",
                 "thinking_level" => "xhigh"
               },
               socket
             )
  end

  test "uses an explicitly selected OpenAI model instead of the fallback model" do
    config = %Config{
      provider: "openai",
      model: "gpt-5.6-sol",
      thinking_level: "max",
      openai_fallback_model: "gpt-5.6-luna",
      system_prompt: "You are Vibe.",
      tools: [],
      execute_tools: fn _calls, state, _callback -> {[], state} end
    }

    payload = AgentRuntime.openai_request_payload([%{role: "user", content: "Hello"}], config)

    assert payload["model"] == "gpt-5.6-sol"
    assert payload["reasoning"] == %{"effort" => "max", "summary" => "auto"}
  end

  test "uses adaptive thinking and output effort for modern Claude models" do
    config = %Config{
      provider: "anthropic",
      model: "claude-sonnet-5",
      thinking_level: "high",
      system_prompt: "You are Vibe.",
      tools: [],
      execute_tools: fn _calls, state, _callback -> {[], state} end
    }

    payload = AgentRuntime.claude_request_payload([%{role: "user", content: "Hello"}], config)

    assert payload["thinking"] == %{"type" => "adaptive"}
    assert payload["output_config"] == %{"effort" => "high"}
  end

  test "does not send unsupported adaptive thinking fields to Haiku 4.5" do
    config = %Config{
      provider: "anthropic",
      model: "claude-haiku-4-5-20251001",
      thinking_level: "medium",
      system_prompt: "You are Vibe.",
      tools: [],
      execute_tools: fn _calls, state, _callback -> {[], state} end
    }

    payload = AgentRuntime.claude_request_payload([%{role: "user", content: "Hello"}], config)

    refute Map.has_key?(payload, "thinking")
    refute Map.has_key?(payload, "output_config")
  end
end
