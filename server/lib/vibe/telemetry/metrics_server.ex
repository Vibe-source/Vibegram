defmodule Vibe.Telemetry.MetricsServer do
  @moduledoc """
  Tiny Plug serving `GET /metrics` in Prometheus text format on METRICS_PORT
  (default 9568). `child_specs/0` returns [] when METRICS_PORT=0 (disabled).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/metrics"} = conn, _opts) do
    body = TelemetryMetricsPrometheus.Core.scrape(Vibe.Telemetry.Metrics.reporter_name())

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  def call(conn, _opts), do: send_resp(conn, 404, "")

  @doc "Plug.Cowboy child spec list for application.ex — empty when METRICS_PORT=0."
  def child_specs do
    case metrics_port() do
      0 -> []
      port -> [{Plug.Cowboy, scheme: :http, plug: __MODULE__, options: [port: port]}]
    end
  end

  defp metrics_port do
    case Integer.parse(System.get_env("METRICS_PORT") || "9568") do
      {port, _} when port >= 0 -> port
      _ -> 9568
    end
  end
end
