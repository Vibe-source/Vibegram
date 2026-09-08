defmodule Vibe.LogScrub do
  @moduledoc """
  Redacts credential-shaped substrings (bearer tokens, agent/bridge secrets,
  API keys) out of log messages via a `:logger` primary filter.
  """

  @patterns [
    {~r/Bearer\s+[A-Za-z0-9\-_.=]+/i, "Bearer [REDACTED]"},
    {~r/(x-vibe-agent-secret\W{1,4})[^\s"'}]+/i, "\\1[REDACTED]"},
    {~r/(x-vibe-bridge-token\W{1,4})[^\s"'}]+/i, "\\1[REDACTED]"},
    {~r/sk-[A-Za-z0-9_-]{10,}/, "sk-[REDACTED]"},
    {~r/(secret\W{1,3})[^\s"'}]+/i, "\\1[REDACTED]"},
    {~r/(token\W{1,3})[^\s"'}]+/i, "\\1[REDACTED]"}
  ]

  @doc "Installs the redaction filter. Call once at boot, before children start."
  def install do
    :logger.add_primary_filter(:vibe_log_scrub, {&__MODULE__.filter/2, []})
  end

  @doc false
  def filter(%{msg: {:string, chardata}} = event, _extra) do
    %{event | msg: {:string, chardata |> IO.iodata_to_binary() |> scrub()}}
  rescue
    _ -> event
  end

  def filter(event, _extra), do: event

  @doc "Redacts credential-shaped substrings in `text`."
  def scrub(text) when is_binary(text) do
    Enum.reduce(@patterns, text, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  def scrub(other), do: other
end
