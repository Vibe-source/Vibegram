defmodule VibeAgents.Outbox do
  @moduledoc """
  Batches `outbox_events` (ordered by run_id, seq) to the core's `POST /internal/v1/agent-
  events` every 150ms or on `notify/0`; exponential backoff (1s → 60s) per row on failure.
  """
  use GenServer
  require Logger
  import Ecto.Query
  alias VibeAgents.Repo
  alias VibeAgents.Schemas.OutboxEvent

  @tick_ms 150
  @batch_limit 200
  @min_backoff_ms 1_000
  @max_backoff_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Nudge an immediate flush attempt (called after Events.emit inserts a row)."
  def notify do
    if enabled?(), do: GenServer.cast(__MODULE__, :flush)
    :ok
  end

  @doc "Runs one flush in the caller's process (tests drive delivery with this)."
  def flush_now, do: flush()

  @impl true
  def init(_opts) do
    if enabled?(), do: schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:flush, state) do
    flush()
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    flush()
    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp enabled?, do: Application.get_env(:vibe_agents, :background_jobs, true)

  # A run with a deferred row must not ship its later rows first: core appends
  # text deltas in arrival order and never resequences.
  defp flush do
    now = DateTime.utc_now()

    blocked =
      OutboxEvent
      |> where([o], is_nil(o.delivered_at) and not is_nil(o.next_attempt_at) and o.next_attempt_at > ^now)
      |> select([o], o.run_id)
      |> distinct(true)

    rows =
      OutboxEvent
      |> where([o], is_nil(o.delivered_at) and (is_nil(o.next_attempt_at) or o.next_attempt_at <= ^now))
      |> where([o], o.run_id not in subquery(blocked))
      |> order_by([o], asc: o.run_id, asc: o.seq)
      |> limit(@batch_limit)
      |> Repo.all()

    if rows != [] do
      deliver_batch(rows)
    end
  end

  defp deliver_batch(rows) do
    bodies = Enum.map(rows, & &1.body)

    case VibeAgents.CoreClient.send_events(bodies) do
      {:ok, _resp} ->
        ids = Enum.map(rows, & &1.id)
        Repo.update_all(from(o in OutboxEvent, where: o.id in ^ids), set: [delivered_at: DateTime.utc_now()])

      {:error, reason} ->
        Logger.warning("[VibeAgents.Outbox] delivery failed (#{inspect(reason)}); backing off #{length(rows)} row(s)")
        Enum.each(rows, &backoff/1)
    end
  end

  defp backoff(%OutboxEvent{} = row) do
    attempts = row.attempts + 1
    delay_ms = min(@max_backoff_ms, @min_backoff_ms * Integer.pow(2, min(attempts - 1, 16)))
    next_attempt_at = DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)

    if delay_ms == @max_backoff_ms and rem(attempts, 20) == 0 do
      Logger.error(
        "[VibeAgents.Outbox] run=#{row.run_id} seq=#{row.seq} undelivered after #{attempts} attempts"
      )
    end

    row
    |> OutboxEvent.changeset(%{attempts: attempts, next_attempt_at: next_attempt_at})
    |> Repo.update()
  end

end
