defmodule VibeContracts.Redact do
  @moduledoc "Scrubs secrets from tool inputs (by key) and free text (by pattern) before logging/relay."

  @sensitive_key ~r/(secret|token|password|passwd|api[_-]?key|authorization|cookie|set-cookie|bearer)/i
  @max_string_length 2_000
  @redacted "[redacted]"

  @text_patterns [
    {~r/Bearer\s+[A-Za-z0-9\-_.=]+/, "Bearer [redacted]"},
    {~r/sk-[A-Za-z0-9]{8,}/, "[redacted]"},
    {~r/vak_[A-Za-z0-9]{8,}/, "[redacted]"},
    {~r/x-vibe-agent-secret:\s*\S+/i, "x-vibe-agent-secret: [redacted]"}
  ]

  @doc "Recursively redacts values whose key looks sensitive; truncates long strings."
  @spec tool_input(term()) :: term()
  def tool_input(value), do: redact_value(value)

  @doc "Scrubs Bearer/sk-…/vak_…/x-vibe-agent-secret patterns out of free text."
  @spec text(binary()) :: binary()
  def text(value) when is_binary(value) do
    Enum.reduce(@text_patterns, value, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  def text(value), do: value

  defp redact_value(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      if sensitive_key?(k), do: {k, @redacted}, else: {k, redact_value(v)}
    end)
  end

  defp redact_value(list) when is_list(list), do: Enum.map(list, &redact_value/1)
  defp redact_value(str) when is_binary(str), do: truncate(str)
  defp redact_value(other), do: other

  defp sensitive_key?(key) when is_binary(key), do: Regex.match?(@sensitive_key, key)
  defp sensitive_key?(key) when is_atom(key), do: sensitive_key?(Atom.to_string(key))
  defp sensitive_key?(_key), do: false

  defp truncate(str) do
    if String.length(str) > @max_string_length do
      String.slice(str, 0, @max_string_length) <> "…"
    else
      str
    end
  end
end
