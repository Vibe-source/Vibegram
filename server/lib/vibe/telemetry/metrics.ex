defmodule Vibe.Telemetry.Metrics do
  @moduledoc """
  Telemetry.Metrics definitions scraped by TelemetryMetricsPrometheus.Core: Phoenix endpoint
  duration.
  """
  import Telemetry.Metrics

  @reporter_name :vibe_prometheus_metrics
  def reporter_name, do: @reporter_name

  def metrics do
    [
      distribution("phoenix.endpoint.stop.duration.milliseconds",
        event_name: [:phoenix, :endpoint, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),
      distribution("vibe.repo.query.total_time.milliseconds",
        event_name: [:vibe, :repo, :query],
        measurement: :total_time,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500]]
      ),
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),
      counter("vibe.rate_limit.blocked.count",
        event_name: [:vibe, :rate_limit, :blocked],
        tags: [:type]
      ),
      counter("vibe.cache.token.count",
        event_name: [:vibe, :cache, :token],
        tags: [:result]
      )
    ]
  end

  @doc "TelemetryMetricsPrometheus.Core child spec for application.ex."
  def reporter_child_spec do
    {TelemetryMetricsPrometheus.Core, metrics: metrics(), name: @reporter_name}
  end
end
