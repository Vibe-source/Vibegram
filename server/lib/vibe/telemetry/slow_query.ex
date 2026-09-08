defmodule Vibe.Telemetry.SlowQuery do
  @moduledoc """
  Logs Ecto queries slower than SLOW_QUERY_MS (default 500) at :notice, with
  source/queue/query time and the first 200 chars of the SQL (no params).
  """
  require Logger

  @event [:vibe, :repo, :query]

  @doc "Attaches the handler; call once from application.ex before the Repo starts serving."
  def attach do
    case :telemetry.attach(__MODULE__, @event, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  def handle_event(@event, measurements, metadata, _config) do
    total_ms = native_to_ms(measurements[:total_time])

    if total_ms > threshold_ms() do
      Logger.notice(
        "[SlowQuery] #{total_ms}ms source=#{metadata[:source] || "?"} " <>
          "queue=#{native_to_ms(measurements[:queue_time])}ms " <>
          "query_time=#{native_to_ms(measurements[:query_time])}ms " <>
          "query=#{query_excerpt(metadata[:query])}"
      )
    end

    :ok
  end

  defp native_to_ms(nil), do: 0
  defp native_to_ms(native), do: System.convert_time_unit(native, :native, :millisecond)

  defp query_excerpt(query) when is_binary(query), do: String.slice(query, 0, 200)
  defp query_excerpt(_), do: ""

  defp threshold_ms do
    case Integer.parse(System.get_env("SLOW_QUERY_MS") || "500") do
      {ms, _} when ms > 0 -> ms
      _ -> 500
    end
  end
end
