defmodule VibeAgents.Runs.Janitor do
  @moduledoc """
  Hourly sweep: cancels abandoned `waiting_*` runs past their TTL, and fails `running` rows
  whose server died without a live Registry entry (a case the crash/timeout handlers miss).
  """
  use GenServer
  require Logger
  import Ecto.Query
  alias VibeAgents.Repo
  alias VibeAgents.Runs.Events
  alias VibeAgents.Schemas.AgentRun

  @first_sweep_ms 5 * 60 * 1000
  @sweep_interval_ms 60 * 60 * 1000

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    Process.send_after(self(), :sweep, @first_sweep_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    if Application.get_env(:vibe_agents, :background_jobs, true), do: sweep()
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, state}
  end

  @doc "Runs one sweep pass. Exported for tests and manual invocation."
  def sweep do
    expire_abandoned_waits()
    fail_stale_running()
  end

  defp expire_abandoned_waits do
    ttl_days = Application.get_env(:vibe_agents, :waiting_run_ttl_days, 7)
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_days * 86_400, :second)

    AgentRun
    |> where([r], r.status in ^AgentRun.waiting_statuses() and r.updated_at < ^cutoff)
    |> Repo.all()
    |> Enum.each(fn run ->
      updated =
        run
        |> AgentRun.update_changeset(%{status: "cancelled", error: "expired", finished_at: DateTime.utc_now()})
        |> Repo.update!()

      Events.emit(updated, "run.cancelled", %{"reason" => "expired"})
      if pid = server_pid(run.id), do: GenServer.stop(pid, :normal)
    end)
  rescue
    error -> Logger.error("[VibeAgents.Runs.Janitor] expire_abandoned_waits: #{Exception.format(:error, error, __STACKTRACE__)}")
  end

  defp fail_stale_running do
    max_run_seconds = Application.get_env(:vibe_agents, :max_run_seconds, 1200)
    cutoff = DateTime.add(DateTime.utc_now(), -2 * max_run_seconds, :second)

    AgentRun
    |> where([r], r.status == "running" and r.started_at < ^cutoff)
    |> Repo.all()
    |> Enum.reject(&server_pid(&1.id))
    |> Enum.each(fn run ->
      updated =
        run
        |> AgentRun.update_changeset(%{status: "failed", error: "stale_run", finished_at: DateTime.utc_now()})
        |> Repo.update!()

      Events.emit(updated, "run.failed", %{"error" => "The runtime lost this run.", "code" => "stale_run"})
    end)
  rescue
    error -> Logger.error("[VibeAgents.Runs.Janitor] fail_stale_running: #{Exception.format(:error, error, __STACKTRACE__)}")
  end

  defp server_pid(run_id) do
    case Registry.lookup(VibeAgents.Runs.Registry, to_string(run_id)) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
