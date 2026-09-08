defmodule Vibe.Retention do
  use GenServer

  require Logger

  alias Vibe.Repo

  @first_run 5 * 60 * 1000
  @interval 6 * 60 * 60 * 1000
  @batch_size 5_000
  @batch_pause 200
  @receipt_retention_days 30

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    if enabled?(), do: Process.send_after(self(), :cleanup, @first_run)
    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    run_once()
    if enabled?(), do: Process.send_after(self(), :cleanup, @interval)
    {:noreply, state}
  end

  def run_once do
    if enabled?() do
      audit_cutoff = cutoff(retention_days())
      audit_count = delete_batches(:audit_events, audit_cutoff)
      Logger.info("Retention deleted #{audit_count} audit_events rows")

      if receipts_table_exists?() do
        receipt_cutoff = cutoff(@receipt_retention_days)
        receipt_count = delete_batches(:agent_run_receipts, receipt_cutoff)
        Logger.info("Retention deleted #{receipt_count} agent_run_receipts rows")
      end
    end

    :ok
  end

  defp enabled?, do: Application.get_env(:vibe, :background_jobs, true)

  defp retention_days do
    case Integer.parse(System.get_env("AUDIT_EVENTS_RETENTION_DAYS") || "365") do
      {days, ""} when days >= 0 -> days
      _ -> 365
    end
  end

  defp cutoff(days) do
    DateTime.utc_now()
    |> DateTime.add(-days * 86_400, :second)
    |> DateTime.truncate(:second)
  end

  defp receipts_table_exists? do
    %{rows: [[table]]} = Repo.query!("SELECT to_regclass('public.agent_run_receipts')")
    not is_nil(table)
  end

  defp delete_batches(table, cutoff, total \\ 0) do
    key = id_column(table)
    sql = "DELETE FROM #{table} WHERE #{key} IN (SELECT #{key} FROM #{table} WHERE #{timestamp_column(table)} < $1 ORDER BY #{key} LIMIT #{@batch_size})"
    %{num_rows: deleted} = Repo.query!(sql, [cutoff])

    if deleted == 0 do
      total
    else
      Process.sleep(@batch_pause)
      delete_batches(table, cutoff, total + deleted)
    end
  end

  defp id_column(:audit_events), do: "id"
  defp id_column(:agent_run_receipts), do: "run_id"

  defp timestamp_column(:audit_events), do: "inserted_at"
  defp timestamp_column(:agent_run_receipts), do: "updated_at"
end
