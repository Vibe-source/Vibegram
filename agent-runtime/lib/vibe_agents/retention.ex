defmodule VibeAgents.Retention do
  use GenServer

  require Logger

  alias VibeAgents.Repo

  @first_run_ms :timer.minutes(5)
  @interval_ms :timer.hours(6)
  @batch_size 5_000
  @batch_pause_ms 200

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def run_once do
    outbox_count = delete_batches(:outbox, outbox_cutoff())
    run_events_count = delete_batches(:run_events, run_events_cutoff())

    Logger.info("[VibeAgents.Retention] table=outbox_events deleted=#{outbox_count}")
    Logger.info("[VibeAgents.Retention] table=agent_run_events deleted=#{run_events_count}")

    %{outbox_events: outbox_count, agent_run_events: run_events_count}
  end

  @impl true
  def init(_opts) do
    if enabled?(), do: Process.send_after(self(), :run, @first_run_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:run, state) do
    run_once()
    Process.send_after(self(), :run, @interval_ms)
    {:noreply, state}
  end

  defp delete_batches(table, cutoff, total \\ 0) do
    deleted = delete_batch(table, cutoff)

    if deleted == 0 do
      total
    else
      Process.sleep(@batch_pause_ms)
      delete_batches(table, cutoff, total + deleted)
    end
  end

  defp delete_batch(:outbox, cutoff) do
    query = """
    DELETE FROM outbox_events
    WHERE id IN (
      SELECT id FROM outbox_events
      WHERE delivered_at < $1
      ORDER BY id
      LIMIT #{@batch_size}
    )
    """

    %{num_rows: count} = Ecto.Adapters.SQL.query!(Repo, query, [cutoff])
    count
  end

  defp delete_batch(:run_events, cutoff) do
    query = """
    DELETE FROM agent_run_events
    WHERE id IN (
      SELECT e.id FROM agent_run_events e
      JOIN agent_runs r ON r.id = e.run_id
      WHERE r.finished_at < $1
      ORDER BY e.id
      LIMIT #{@batch_size}
    )
    """

    %{num_rows: count} = Ecto.Adapters.SQL.query!(Repo, query, [cutoff])
    count
  end

  defp outbox_cutoff do
    DateTime.add(DateTime.utc_now(), -retention_days("OUTBOX_RETENTION_DAYS", 7), :day)
  end

  defp run_events_cutoff do
    DateTime.add(DateTime.utc_now(), -retention_days("RUN_EVENTS_RETENTION_DAYS", 30), :day)
  end

  defp retention_days(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  defp enabled? do
    Application.get_env(:vibe_agents, :background_jobs, true)
  end
end
