defmodule Vibe.AI.TeamRunMonitor do
  @moduledoc """
  Deterministic, zero-token watchdog for one coordinated team run.
  """

  use GenServer, restart: :transient

  require Logger

  alias Vibe.AI.LocalAgentWorker

  @registry Vibe.AI.TeamRunRegistry
  @supervisor Vibe.AI.TeamRunMonitorSupervisor

  # Sweep cadence and budgets.
  @tick_ms 45_000
  @first_frame_grace_ms 240_000
  @stall_ms 300_000
  @row_retry_limit 1
  @run_retry_budget 3
  @queue_age_cap_ms 30 * 60_000
  @idle_shutdown_ms 90 * 60_000
  @contract_freeze_timeout_ms 180_000

  # ── Public API (all fire-and-forget; failures must never break dispatch) ──

  def ensure_started(chat_id, team_run_id)
      when is_binary(chat_id) and is_binary(team_run_id) do
    case Registry.lookup(@registry, {chat_id, team_run_id}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(
          @supervisor,
          {__MODULE__, {chat_id, team_run_id}}
        )
        |> case do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  rescue
    error ->
      Logger.warning("[TeamRunMonitor] ensure_started failed: #{Exception.message(error)}")
      {:error, error}
  end

  def note_spawned(chat_id, team_run_id, worker_handle, task_id) do
    cast(chat_id, team_run_id, {:spawned, worker_handle, task_id})
  end

  @doc """
  Progress frame heartbeat.
  """
  def note_heartbeat(
        chat_id,
        team_run_id,
        worker_handle,
        queued? \\ false,
        progress_bytes \\ nil
      ) do
    cast(
      chat_id,
      team_run_id,
      {:heartbeat, worker_handle, queued? == true, normalize_progress_bytes(progress_bytes)}
    )
  end

  def note_settled(
        chat_id,
        team_run_id,
        worker_handle,
        ok?,
        usage_limit?,
        retryable_crash? \\ true
      ) do
    cast(
      chat_id,
      team_run_id,
      {:settled, worker_handle, ok? == true, usage_limit? == true, retryable_crash? == true}
    )
  end

  # Cancel only tears down an already-armed monitor; it never starts one.
  def note_cancelled(chat_id, team_run_id)
      when is_binary(chat_id) and is_binary(team_run_id) do
    case Registry.lookup(@registry, {chat_id, team_run_id}) do
      [{pid, _}] -> GenServer.cast(pid, :cancelled)
      [] -> :ok
    end
  rescue
    _ -> :ok
  end

  def note_cancelled(_, _), do: :ok

  defp cast(chat_id, team_run_id, msg)
       when is_binary(chat_id) and is_binary(team_run_id) do
    case ensure_started(chat_id, team_run_id) do
      {:ok, pid} -> GenServer.cast(pid, msg)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp cast(_, _, _), do: :ok


  def start_link({chat_id, team_run_id}) do
    GenServer.start_link(__MODULE__, {chat_id, team_run_id},
      name: {:via, Registry, {@registry, {chat_id, team_run_id}}}
    )
  end

  def child_spec({chat_id, team_run_id}) do
    %{
      id: {__MODULE__, chat_id, team_run_id},
      start: {__MODULE__, :start_link, [{chat_id, team_run_id}]},
      restart: :transient
    }
  end

  @impl true
  def init({chat_id, team_run_id}) do
    now = now_ms()

    case LocalAgentWorker.fetch_supervisor_run_state(chat_id, team_run_id) do
      %{mode: "supervisor"} = run ->
        state = %{
          chat_id: chat_id,
          team_run_id: team_run_id,
          lead: Map.get(run, :lead_worker),
          rows: rehydrate_rows(chat_id, team_run_id, now),
          run_retries: 0,
          last_activity: now,
          finalized: false
        }

        Process.send_after(self(), :tick, @tick_ms)
        Logger.info("[TeamRunMonitor] armed chat=#{chat_id} run=#{team_run_id}")
        {:ok, state}

      _ ->
        :ignore
    end
  end

  defp rehydrate_rows(chat_id, team_run_id, now) do
    LocalAgentWorker.team_workers_status(chat_id, team_run_id)
    |> Enum.reduce(%{}, fn entry, acc ->
      handle = entry["worker"] || entry[:worker]
      status = entry["status"] || entry[:status]

      if is_binary(handle) do
        spawned_at =
          entry["startedAt"] || entry[:started_at] || entry["started_at"] || now

        Map.put(acc, handle, %{
          beat: now,
          last_frame_at: now,
          last_progress_at: now,
          last_progress_bytes: entry["progressBytes"] || entry[:progress_bytes] || 0,
          spawned_at: spawned_at,
          retries: 0,
          terminal: status in ["done", "failed", "reassigned", "cancelled"]
        })
      else
        acc
      end
    end)
  end

  @impl true
  def handle_cast({:spawned, handle, _task_id}, state) when is_binary(handle) do
    now = now_ms()

    rows =
      Map.put(state.rows, handle, %{
        beat: now,
        last_frame_at: now,
        last_progress_at: now,
        last_progress_bytes: 0,
        spawned_at: now,
        retries: Map.get(state.rows, handle, %{})[:retries] || 0,
        terminal: false
      })

    {:noreply, %{state | rows: rows, last_activity: now}}
  end

  def handle_cast({:heartbeat, handle, queued?, progress_bytes}, state)
      when is_binary(handle) do
    now = now_ms()

    rows =
      Map.update(
        state.rows,
        handle,
        %{
          beat: now,
          last_frame_at: now,
          last_progress_at: now,
          last_progress_bytes: progress_bytes || 0,
          spawned_at: now,
          retries: 0,
          terminal: false,
          queued_since: if(queued?, do: now)
        },
        fn row ->
          queued_since =
            cond do
              queued? -> Map.get(row, :queued_since) || now
              true -> nil
            end

          previous_bytes = Map.get(row, :last_progress_bytes)

          bytes_changed? =
            is_integer(progress_bytes) and
              (not is_integer(previous_bytes) or progress_bytes != previous_bytes)

          row
          |> Map.merge(%{beat: now, last_frame_at: now, terminal: false})
          |> then(fn updated ->
            if bytes_changed? and not queued? do
              updated
              |> Map.put(:last_progress_bytes, progress_bytes)
              |> Map.put(:last_progress_at, now)
            else
              updated
            end
          end)
          |> Map.put(:queued_since, queued_since)
        end
      )

    {:noreply, %{state | rows: rows, last_activity: now}}
  end

  def handle_cast({:settled, handle, ok?, usage_limit?, retryable_crash?}, state)
      when is_binary(handle) do
    now = now_ms()

    row =
      Map.get(state.rows, handle, %{
        beat: now,
        last_frame_at: now,
        last_progress_at: now,
        last_progress_bytes: 0,
        spawned_at: now,
        retries: 0,
        terminal: false
      })

    state =
      cond do
        row.terminal ->
          state

        ok? ->
          put_row(state, handle, %{row | terminal: true, beat: now})

        handle == state.lead ->
          put_row(state, handle, %{row | terminal: true, beat: now})

        usage_limit? ->
          reassign_row(state, handle, row, now)

        not retryable_crash? ->
          Logger.info(
            "[TeamRunMonitor] external signal exit — no retry chat=#{state.chat_id} " <>
              "run=#{state.team_run_id} worker=#{handle}"
          )

          put_row(state, handle, %{row | terminal: true, beat: now})

        true ->
          retry_row(state, handle, row, now, "failed")
      end

    state =
      state
      |> Map.put(:last_activity, now)
      |> check_contract_barrier(now)
      |> maybe_finalize()

    {:noreply, state}
  end

  def handle_cast(:cancelled, state) do
    Logger.info("[TeamRunMonitor] run cancelled chat=#{state.chat_id} run=#{state.team_run_id}")

    {:stop, :normal, %{state | finalized: true}}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, state) do
    now = now_ms()
    state = check_contract_barrier(state, now)

    state =
      state.rows
      |> Enum.filter(fn {_handle, row} ->
        not row.terminal and is_integer(Map.get(row, :queued_since)) and
          now - row.queued_since > @queue_age_cap_ms
      end)
      |> Enum.reduce(state, fn {handle, row}, acc ->
        Logger.warning(
          "[TeamRunMonitor] queue-age cap hit chat=#{acc.chat_id} run=#{acc.team_run_id} worker=#{handle}"
        )

        LocalAgentWorker.monitor_mark_worker(
          acc.chat_id,
          acc.team_run_id,
          handle,
          "failed",
          "queued too long — bridge slot never freed"
        )

        put_row(acc, handle, %{row | terminal: true, beat: now})
      end)

    state =
      state.rows
      |> Enum.filter(fn {handle, row} ->
        handle != state.lead and not row.terminal and
          is_nil(Map.get(row, :queued_since)) and stalled?(handle, row, state, now)
      end)
      |> Enum.reduce(state, fn {handle, row}, acc ->
        retry_row(acc, handle, row, now, "stalled")
      end)
      |> check_contract_barrier(now)
      |> maybe_finalize()

    cond do
      state.finalized ->
        {:stop, :normal, state}

      now - state.last_activity > @idle_shutdown_ms ->
        Logger.info(
          "[TeamRunMonitor] idle shutdown chat=#{state.chat_id} run=#{state.team_run_id}"
        )

        {:stop, :normal, state}

      true ->
        Process.send_after(self(), :tick, @tick_ms)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}


  defp stalled?(handle, row, state, now) do
    last_progress_at = Map.get(row, :last_progress_at) || row.spawned_at
    last_progress_bytes = Map.get(row, :last_progress_bytes) || 0
    silent_for = now - last_progress_at
    grace = if(last_progress_bytes == 0, do: @first_frame_grace_ms, else: @stall_ms)

    silent_for > grace and durable_status(state, handle) == "running"
  end

  defp durable_status(state, handle) do
    LocalAgentWorker.team_workers_status(state.chat_id, state.team_run_id)
    |> Enum.find_value(fn entry ->
      if (entry["worker"] || entry[:worker]) == handle, do: entry["status"] || entry[:status]
    end)
  end

  defp check_contract_barrier(state, now) do
    contracts = LocalAgentWorker.team_contracts(state.chat_id, state.team_run_id)

    if contracts == [] do
      state
    else
      durable_rows =
        LocalAgentWorker.team_workers_status(state.chat_id, state.team_run_id)
        |> Map.new(fn entry -> {entry["worker"] || entry[:worker], entry} end)

      fallback_owners =
        contracts
        |> Enum.filter(fn contract ->
          owner = contract["owner"]
          entry = durable_rows[owner] || %{}
          status = entry["status"] || entry[:status]

          spawned_at =
            entry["startedAt"] || entry[:started_at] || entry["started_at"]

          status in ["done", "failed", "cancelled", "reassigned"] or
            (is_integer(spawned_at) and now - spawned_at >= @contract_freeze_timeout_ms)
        end)
        |> Enum.map(& &1["owner"])
        |> Enum.uniq()

      LocalAgentWorker.monitor_contract_barrier(
        state.chat_id,
        state.team_run_id,
        fallback_owners
      )

      state
    end
  rescue
    error ->
      Logger.warning(
        "[TeamRunMonitor] contract check failed chat=#{state.chat_id} run=#{state.team_run_id}: " <>
          Exception.message(error)
      )

      state
  end

  defp retry_row(state, handle, row, now, reason) do
    cond do
      row.retries >= @row_retry_limit or state.run_retries >= @run_retry_budget ->
        Logger.warning(
          "[TeamRunMonitor] #{reason} retries exhausted chat=#{state.chat_id} run=#{state.team_run_id} worker=#{handle}"
        )

        LocalAgentWorker.monitor_mark_worker(
          state.chat_id,
          state.team_run_id,
          handle,
          "failed",
          "#{reason} — retries exhausted"
        )

        put_row(state, handle, %{row | terminal: true, beat: now})

      true ->
        Logger.info(
          "[TeamRunMonitor] #{reason} → retry chat=#{state.chat_id} run=#{state.team_run_id} worker=#{handle} attempt=#{row.retries + 1}"
        )

        case LocalAgentWorker.monitor_retry_worker(
               state.chat_id,
               state.team_run_id,
               handle,
               reason
             ) do
          :ok ->
            state
            |> put_row(handle, %{
              row
              | retries: row.retries + 1,
                beat: now,
                last_frame_at: now,
                last_progress_at: now,
                last_progress_bytes: 0,
                spawned_at: now
            })
            |> Map.update!(:run_retries, &(&1 + 1))

          {:error, _} ->
            LocalAgentWorker.monitor_mark_worker(
              state.chat_id,
              state.team_run_id,
              handle,
              "failed",
              "#{reason} — retry dispatch failed"
            )

            put_row(state, handle, %{row | terminal: true, beat: now})
        end
    end
  end

  defp reassign_row(state, handle, row, now) do
    if state.run_retries >= @run_retry_budget do
      LocalAgentWorker.monitor_mark_worker(
        state.chat_id,
        state.team_run_id,
        handle,
        "failed",
        "usage limit — retry budget exhausted"
      )

      put_row(state, handle, %{row | terminal: true, beat: now})
    else
      case LocalAgentWorker.monitor_reassign_worker(state.chat_id, state.team_run_id, handle) do
        {:ok, fallback} ->
          Logger.info(
            "[TeamRunMonitor] usage-limit reassign chat=#{state.chat_id} run=#{state.team_run_id} #{handle} → #{fallback}"
          )

          state
          |> put_row(handle, %{row | terminal: true, beat: now})
          |> put_row(fallback, %{
            beat: now,
            last_frame_at: now,
            last_progress_at: now,
            last_progress_bytes: 0,
            spawned_at: now,
            retries: 0,
            terminal: false
          })
          |> Map.update!(:run_retries, &(&1 + 1))

        {:error, :no_fallback} ->
          LocalAgentWorker.monitor_mark_worker(
            state.chat_id,
            state.team_run_id,
            handle,
            "failed",
            "usage limit — no idle fallback provider"
          )

          put_row(state, handle, %{row | terminal: true, beat: now})

        {:error, _} ->
          put_row(state, handle, %{row | terminal: true, beat: now})
      end
    end
  end

  defp put_row(state, handle, row) when is_binary(handle) do
    %{state | rows: Map.put(state.rows, handle, row)}
  end

  defp maybe_finalize(%{finalized: true} = state), do: state

  defp maybe_finalize(state) do
    statuses =
      LocalAgentWorker.team_workers_status(state.chat_id, state.team_run_id)
      |> Enum.map(&(&1["status"] || &1[:status]))

    all_terminal =
      statuses != [] and
        Enum.all?(statuses, &(&1 in ["done", "failed", "reassigned", "cancelled"]))

    if all_terminal do
      LocalAgentWorker.monitor_finalize_run(state.chat_id, state.team_run_id)

      Logger.info(
        "[TeamRunMonitor] run terminal chat=#{state.chat_id} run=#{state.team_run_id} statuses=#{inspect(statuses)}"
      )

      %{state | finalized: true}
    else
      state
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp normalize_progress_bytes(value) when is_integer(value) and value >= 0, do: value

  defp normalize_progress_bytes(value) when is_binary(value) do
    case Integer.parse(value) do
      {bytes, _} when bytes >= 0 -> bytes
      _ -> nil
    end
  end

  defp normalize_progress_bytes(_), do: nil
end
