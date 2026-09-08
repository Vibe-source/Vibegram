defmodule Vibe.AI.ModelRegistry do
  @moduledoc false

  @default %{
    provider: "anthropic",
    model_id: "claude-sonnet-5",
    thinking_level: "medium"
  }

  @providers [
    %{
      id: "anthropic",
      name: "Anthropic",
      default_model_id: "claude-sonnet-5",
      models: [
        %{
          id: "claude-fable-5",
          name: "Claude Fable 5",
          description: "Deep reasoning for the most demanding agent tasks.",
          tier: "max",
          recommended: false,
          thinking_levels: ["low", "medium", "high", "xhigh", "max"],
          default_thinking_level: "medium"
        },
        %{
          id: "claude-opus-4-8",
          name: "Claude Opus 4.8",
          description: "High-capability reasoning for complex work.",
          tier: "premium",
          recommended: false,
          thinking_levels: ["low", "medium", "high", "xhigh", "max"],
          default_thinking_level: "medium"
        },
        %{
          id: "claude-sonnet-5",
          name: "Claude Sonnet 5",
          description: "The recommended balance of intelligence, speed, and cost.",
          tier: "balanced",
          recommended: true,
          thinking_levels: ["low", "medium", "high", "xhigh", "max"],
          default_thinking_level: "medium"
        },
        %{
          id: "claude-haiku-4-5-20251001",
          name: "Claude Haiku 4.5",
          description: "Fast, economical responses for lightweight tasks.",
          tier: "fast",
          recommended: false,
          thinking_levels: ["medium"],
          default_thinking_level: "medium"
        }
      ]
    },
    %{
      id: "openai",
      name: "OpenAI",
      default_model_id: "gpt-5.6-luna",
      models: [
        %{
          id: "gpt-5.6-sol",
          name: "GPT-5.6 Sol",
          description: "Maximum capability for complex agent workflows.",
          tier: "max",
          recommended: false,
          thinking_levels: ["low", "medium", "high", "xhigh", "max"],
          default_thinking_level: "medium"
        },
        %{
          id: "gpt-5.6-terra",
          name: "GPT-5.6 Terra",
          description: "Balanced capability for everyday agent work.",
          tier: "balanced",
          recommended: false,
          thinking_levels: ["low", "medium", "high", "xhigh"],
          default_thinking_level: "medium"
        },
        %{
          id: "gpt-5.6-luna",
          name: "GPT-5.6 Luna",
          description: "Fast, cost-efficient responses.",
          tier: "fast",
          recommended: true,
          thinking_levels: ["low", "medium", "high"],
          default_thinking_level: "medium"
        }
      ]
    }
  ]

  def default_selection, do: @default

  def providers, do: @providers

  def provider_ids, do: Enum.map(@providers, & &1.id)

  def public_payload do
    %{
      default: %{
        provider: @default.provider,
        modelId: @default.model_id,
        thinkingLevel: @default.thinking_level
      },
      providers:
        Enum.map(@providers, fn provider ->
          %{
            id: provider.id,
            name: provider.name,
            available: provider_available?(provider.id),
            models: Enum.map(provider.models, &public_model/1)
          }
        end)
    }
  end

  @doc """
  Thinking effort levels a model supports, or nil when the model is unknown here.
  """
  def thinking_levels(provider, model_id) when is_binary(provider) and is_binary(model_id) do
    case model_entry(String.trim(provider), String.trim(model_id)) do
      nil -> nil
      model -> model.thinking_levels
    end
  end

  def thinking_levels(_provider, _model_id), do: nil

  def provider_for_model(model_id) when is_binary(model_id) do
    normalized = String.trim(model_id)

    case Enum.find(@providers, fn provider ->
           Enum.any?(provider.models, &(&1.id == normalized))
         end) do
      nil -> nil
      provider -> provider.id
    end
  end

  def provider_for_model(_model_id), do: nil

  def valid_selection?(provider, model_id) when is_binary(provider) and is_binary(model_id) do
    normalized_provider = String.trim(provider)
    normalized_model = String.trim(model_id)

    Enum.any?(@providers, fn candidate ->
      candidate.id == normalized_provider and
        Enum.any?(candidate.models, &(&1.id == normalized_model))
    end)
  end

  def valid_selection?(_provider, _model_id), do: false

  def valid_thinking_level?(provider, model_id, thinking_level)
      when is_binary(provider) and is_binary(model_id) and is_binary(thinking_level) do
    case model_entry(provider, model_id) do
      nil -> false
      model -> thinking_level in model.thinking_levels
    end
  end

  def valid_thinking_level?(_provider, _model_id, _thinking_level), do: false

  def resolve_selection(attrs, current \\ @default) when is_map(attrs) do
    provider_input =
      fetch_input(attrs, ["model_provider", :model_provider, "modelProvider", :modelProvider])

    model_input = fetch_input(attrs, ["model_id", :model_id, "modelId", :modelId])

    thinking_input =
      fetch_input(attrs, ["thinking_level", :thinking_level, "thinkingLevel", :thinkingLevel])

    current = normalize_current(current)

    with {:ok, selection} <- resolve_model_selection(provider_input, model_input, current),
         {:ok, thinking_level} <- resolve_thinking_level(thinking_input, selection) do
      {:ok, Map.put(selection, :thinking_level, thinking_level)}
    end
  end

  def provider_available?("anthropic") do
    configured?("ANTHROPIC_API_KEY") or configured?("CLAUDE_API_KEY")
  end

  def provider_available?("openai"), do: configured?("OPENAI_API_KEY")
  def provider_available?(_provider), do: false

  defp normalize_current(%{provider: provider, model_id: model_id} = current) do
    if valid_selection?(provider, model_id) do
      thinking_level =
        case Map.get(current, :thinking_level) do
          level when is_binary(level) ->
            if valid_thinking_level?(provider, model_id, level),
              do: level,
              else: default_thinking_level(provider, model_id)

          _ ->
            default_thinking_level(provider, model_id)
        end

      %{provider: provider, model_id: model_id, thinking_level: thinking_level}
    else
      @default
    end
  end

  defp normalize_current(%{"provider" => provider, "model_id" => model_id} = current) do
    normalize_current(%{
      provider: provider,
      model_id: model_id,
      thinking_level: current["thinking_level"] || current["thinkingLevel"]
    })
  end

  defp normalize_current(_current), do: @default

  defp normalize_provider(value) when is_binary(value) do
    provider = value |> String.trim() |> String.downcase()
    if provider in provider_ids(), do: {:ok, provider}, else: {:error, :invalid_model_provider}
  end

  defp normalize_provider(_value), do: {:error, :invalid_model_provider}

  defp normalize_model(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_model_id}
      model_id -> {:ok, model_id}
    end
  end

  defp normalize_model(_value), do: {:error, :invalid_model_id}

  defp default_model_for_provider(provider) do
    case Enum.find(@providers, &(&1.id == provider)) do
      nil -> {:error, :invalid_model_provider}
      entry -> {:ok, entry.default_model_id}
    end
  end

  defp resolve_model_selection(:missing, :missing, current), do: {:ok, current}

  defp resolve_model_selection({:present, provider}, :missing, _current) do
    with {:ok, provider} <- normalize_provider(provider),
         {:ok, model_id} <- default_model_for_provider(provider) do
      {:ok, %{provider: provider, model_id: model_id}}
    end
  end

  defp resolve_model_selection(:missing, {:present, model_id}, _current) do
    with {:ok, model_id} <- normalize_model(model_id),
         provider when is_binary(provider) <- provider_for_model(model_id) do
      {:ok, %{provider: provider, model_id: model_id}}
    else
      _ -> {:error, :invalid_model_id}
    end
  end

  defp resolve_model_selection({:present, provider}, {:present, model_id}, _current) do
    with {:ok, provider} <- normalize_provider(provider),
         {:ok, model_id} <- normalize_model(model_id),
         true <- valid_selection?(provider, model_id) do
      {:ok, %{provider: provider, model_id: model_id}}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_model_selection}
    end
  end

  defp resolve_thinking_level(:missing, selection) do
    {:ok, default_thinking_level(selection.provider, selection.model_id)}
  end

  defp resolve_thinking_level({:present, value}, selection) do
    with {:ok, thinking_level} <- normalize_thinking_level(value),
         true <-
           valid_thinking_level?(
             selection.provider,
             selection.model_id,
             thinking_level
           ) do
      {:ok, thinking_level}
    else
      _ -> {:error, :invalid_thinking_level}
    end
  end

  defp normalize_thinking_level(value) when is_binary(value) do
    thinking_level = value |> String.trim() |> String.downcase()

    if thinking_level in ["low", "medium", "high", "xhigh", "max"],
      do: {:ok, thinking_level},
      else: {:error, :invalid_thinking_level}
  end

  defp normalize_thinking_level(_value), do: {:error, :invalid_thinking_level}

  defp default_thinking_level(provider, model_id) do
    case model_entry(provider, model_id) do
      nil -> @default.thinking_level
      model -> model.default_thinking_level
    end
  end

  defp model_entry(provider, model_id) do
    with %{models: models} <- Enum.find(@providers, &(&1.id == provider)) do
      Enum.find(models, &(&1.id == model_id))
    end
  end

  defp public_model(model) do
    model
    |> Map.drop([:thinking_levels, :default_thinking_level])
    |> Map.put(:thinkingLevels, model.thinking_levels)
    |> Map.put(:defaultThinkingLevel, model.default_thinking_level)
  end

  defp fetch_input(attrs, keys) do
    Enum.find_value(keys, :missing, fn key ->
      if Map.has_key?(attrs, key), do: {:present, Map.get(attrs, key)}
    end)
  end

  defp configured?(name) do
    case System.get_env(name) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end
end
