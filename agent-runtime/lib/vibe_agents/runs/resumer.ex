defmodule VibeAgents.Runs.Resumer do
  @moduledoc """
  Boot-time cleanup (spec §3.10): a `status = "running"` row at boot means the VM died
  mid-flight with no clean suspend point — mark it failed. A `waiting_*` row was suspended
  cleanly (its `state` was persisted first) — re-arm a cold `VibeAgents.Runs.Server` for it.
  """
  require Logger
  import Ecto.Query
  alias VibeAgents.Repo
  alias VibeAgents.Runs.Events
  alias VibeAgents.Schemas.AgentRun

  # One-shot:
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}
  end

  def start_link do
    Task.start_link(fn ->
      if Application.get_env(:vibe_agents, :background_jobs, true), do: run()
    end)
  end

  def run do
    fail_stale_running()
    rearm_waiting()
  end

  defp fail_stale_running do
    AgentRun
    |> where([r], r.status == "running")
    |> Repo.all()
    |> Enum.each(fn run ->
      updated =
        run
        |> AgentRun.update_changeset(%{status: "failed", error: "runtime_restart", finished_at: DateTime.utc_now()})
        |> Repo.update!()

      Events.emit(updated, "run.failed", %{"error" => "The runtime restarted while this run was in flight.", "code" => "runtime_restart"})
    end)
  rescue
    error -> Logger.error("[VibeAgents.Runs.Resumer] fail_stale_running: #{Exception.format(:error, error, __STACKTRACE__)}")
  end

  defp rearm_waiting do
    AgentRun
    |> where([r], r.status in ^(AgentRun.waiting_statuses() ++ ["queued"]))
    |> Repo.all()
    |> Enum.each(fn run ->
      result =
        if run.status == "queued",
          do: VibeAgents.Runs.Dispatcher.start_or_queue(run.id),
          else: VibeAgents.Runs.Dispatcher.start_run(run.id)

      case result do
        {:ok, _pid} -> :ok
        :queued -> :ok
        {:error, reason} -> Logger.error("[VibeAgents.Runs.Resumer] could not re-arm run #{run.id}: #{inspect(reason)}")
      end
    end)
  rescue
    error -> Logger.error("[VibeAgents.Runs.Resumer] rearm_waiting: #{Exception.format(:error, error, __STACKTRACE__)}")
  end
end
