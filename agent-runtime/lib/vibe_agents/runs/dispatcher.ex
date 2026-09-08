defmodule VibeAgents.Runs.Dispatcher do
  @moduledoc """
  Admission control for runs. Caps live run servers at `:max_concurrent_runs` and
  drains the `queued` backlog as slots free, so a burst queues instead of failing.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias VibeAgents.Repo
  alias VibeAgents.Runs.Server
  alias VibeAgents.Schemas.AgentRun

  @sweep_ms 2_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Live run servers allowed at once on this node."
  def max_concurrent, do: Application.get_env(:vibe_agents, :max_concurrent_runs, 8)

  @doc "Run servers alive right now (the Registry is this node's, see Janitor)."
  def active_count, do: Registry.count(VibeAgents.Runs.Registry)

  @doc "Starts the run when a slot is free, else leaves it `queued` for the sweep."
  def start_or_queue(run_id) do
    if active_count() < max_concurrent() do
      start_run(run_id)
    else
      :queued
    end
  end

  @doc "Starts a run server, treating an already-running one as success."
  def start_run(run_id) do
    case DynamicSupervisor.start_child(VibeAgents.Runs.Supervisor, {Server, run_id: run_id}) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    if Application.get_env(:vibe_agents, :background_jobs, true), do: sweep()
    schedule()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_ms)

  @doc "Runs one drain pass. Exported for tests and manual invocation."
  def sweep do
    free = max_concurrent() - active_count()

    if free > 0 do
      AgentRun
      |> where([r], r.status == "queued")
      |> order_by([r], asc: r.inserted_at)
      |> limit(^free)
      |> Repo.all()
      |> Enum.reject(&live?(&1.id))
      |> Enum.each(&start_run(&1.id))
    end
  rescue
    error ->
      Logger.error("[VibeAgents.Runs.Dispatcher] sweep: #{Exception.format(:error, error, __STACKTRACE__)}")
  end

  defp live?(run_id), do: Registry.lookup(VibeAgents.Runs.Registry, to_string(run_id)) != []
end
