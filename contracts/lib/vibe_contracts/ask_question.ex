defmodule VibeContracts.AskQuestion do
  @moduledoc """
  Normalizes `ask_user` / `run.ask` questions: 1-4 questions, 2-4 options each,
  header <= 12 chars, trims/truncates. Mirrors the core's `agent.ex` `normalize_questions`.
  """

  @max_questions 4
  @min_options 2
  @max_options 4
  @question_max_length 500
  @header_max_length 12
  @label_max_length 80
  @description_max_length 240

  @doc "Normalizes a raw question list into the frozen AskQuestion shape."
  @spec normalize(list()) :: [map()]
  def normalize(list) when is_list(list) do
    list
    |> Enum.map(&normalize_question/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@max_questions)
  end

  def normalize(_list), do: []

  defp normalize_question(question) when is_map(question) do
    text = display_string(fetch(question, "question"), @question_max_length)
    header = display_string(fetch(question, "header"), @header_max_length)
    options = normalize_options(fetch(question, "options") || [])

    if is_binary(text) and is_binary(header) and length(options) >= @min_options do
      %{
        "question" => text,
        "header" => header,
        "multiSelect" =>
          truthy?(fetch(question, "multiSelect") || fetch(question, "multi_select")),
        "options" => options
      }
    end
  end

  defp normalize_question(_question), do: nil

  defp normalize_options(value) when is_list(value) do
    value
    |> Enum.map(&normalize_option/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1["label"])
    |> Enum.take(@max_options)
  end

  defp normalize_options(_value), do: []

  defp normalize_option(option) when is_map(option) do
    case display_string(fetch(option, "label"), @label_max_length) do
      nil ->
        nil

      label ->
        %{
          "label" => label,
          "description" =>
            display_string(fetch(option, "description"), @description_max_length) || ""
        }
    end
  end

  defp normalize_option(_option), do: nil

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp display_string(value, max_length) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, max_length)
    end
  end

  defp display_string(_value, _max_length), do: nil

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false
end
