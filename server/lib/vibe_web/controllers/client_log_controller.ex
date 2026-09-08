defmodule VibeWeb.ClientLogController do
  @moduledoc """
  Ingest for client-side log reports (iOS `VibeLog`, Android).

  Reports are written to the server journal tagged `[ClientLog]`, so they reach
  Loki through the pipeline that already ships `core` — @monitor reads them with
  `deploy/scripts/vibe-logs.sh core -g ClientLog`. No table, so nothing to
  migrate and nothing for a rollback to strand. See docs/vps-logs.md.
  """

  use VibeWeb, :controller

  require Logger

  @max_events 200
  @max_message_bytes 2_000
  @max_field_bytes 120
  @levels ~w(debug info notice warn warning error fault fatal critical)

  def create(conn, params) do
    user = conn.assigns.current_user
    app = client_context(params)

    events =
      params
      |> Map.get("events")
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.take(@max_events)

    Enum.each(events, &log_event(&1, user.id, app))

    json(conn, %{ok: true, accepted: length(events)})
  end

  defp log_event(event, user_id, app) do
    level = level_of(event)

    line =
      [
        "[ClientLog]",
        "user=#{user_id}",
        app,
        "level=#{level}",
        kv(event, "tag", "tag"),
        kv(event, "session", "session"),
        kv(event, "ts", "ts"),
        "msg=#{inspect(field(event, "message", @max_message_bytes))}"
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    case level do
      l when l in ["error", "fault", "fatal", "critical"] -> Logger.error(line)
      l when l in ["warn", "warning"] -> Logger.warning(line)
      _ -> Logger.info(line)
    end
  end

  # Only the shape below is logged; anything else a client sends is dropped.
  defp client_context(params) do
    app = if is_map(params["app"]), do: params["app"], else: %{}

    [
      kv(app, "platform", "platform"),
      kv(app, "version", "version"),
      kv(app, "build", "build"),
      kv(app, "os", "os"),
      kv(app, "device", "device")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp kv(map, key, label) do
    case field(map, key, @max_field_bytes) do
      nil -> nil
      value -> "#{label}=#{sanitize(value)}"
    end
  end

  defp level_of(event) do
    case field(event, "level", 16) do
      nil -> "info"
      value -> if String.downcase(value) in @levels, do: String.downcase(value), else: "info"
    end
  end

  defp field(map, key, limit) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) -> value |> String.slice(0, limit) |> presence()
      value when is_integer(value) or is_float(value) -> to_string(value)
      _ -> nil
    end
  end

  defp field(_map, _key, _limit), do: nil

  defp presence(""), do: nil
  defp presence(value), do: value

  # A client must not be able to forge a log line by putting spaces or newlines in a field.
  defp sanitize(value), do: String.replace(value, ~r/[^\w.\-:@\/+]/u, "_")
end
