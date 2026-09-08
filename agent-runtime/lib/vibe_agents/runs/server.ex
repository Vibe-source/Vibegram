defmodule VibeAgents.Runs.Server do
  @moduledoc """
  One GenServer per run, registered under `VibeAgents.Runs.Registry`. Owns the loop Task,
  enforces `VIBE_AGENTS_MAX_RUN_SECONDS`, and brokers approval/ask/permission decisions.

  A tool needing a decision blocks its OWN task in `await_decision/3` (a plain
  `GenServer.call`) — the outer loop task just waits longer on that one tool, exactly like
  any other tool call, so a live run resumes with full fidelity and no special-casing. Only a
  genuine VM restart loses the blocked caller; `VibeAgents.Runs.Resumer` re-arms those runs
  cold (no live task) and this server resumes them with a synthetic note instead of a replay.
  """
  use GenServer
  require Logger
  alias VibeAgents.Repo
  alias VibeAgents.Runs.{Decisions, Events, Loop}
  alias VibeAgents.Schemas.AgentRun

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, run_id, name: via(run_id))
  end

  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :run_id)}, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  def via(run_id), do: {:via, Registry, {VibeAgents.Runs.Registry, to_string(run_id)}}

  def cancel(pid, attrs), do: GenServer.call(pid, {:cancel, attrs}, 30_000)
  def decide(pid, decision_map), do: GenServer.call(pid, {:decision, decision_map}, 30_000)

  @doc "Called from inside a tool task. Persists the waiting state, then blocks for `timeout`."
  def await_decision(run_id, payload, timeout) do
    case Registry.lookup(VibeAgents.Runs.Registry, to_string(run_id)) do
      [{pid, _}] -> GenServer.call(pid, {:await_decision, payload}, timeout)
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def init(run_id) do
    run = Repo.get(AgentRun, run_id)
    send(self(), :boot)
    {:ok, %{run_id: run_id, run: run, task: nil, timer_ref: nil, awaiting: nil}}
  end

  @impl true
  def handle_info(:boot, %{run: nil} = state), do: {:stop, :normal, state}

  def handle_info(:boot, %{run: run} = state) do
    cond do
      run.status == "queued" ->
        {:noreply, start_task(state, fn -> Loop.run(run) end, status: "running", started_at: DateTime.utc_now())}

      AgentRun.waiting?(run) ->
        {:noreply, rearm(state, run)}

      true ->
        {:stop, :normal, state}
    end
  end

  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = cancel_timer(%{state | task: nil})
    run = Repo.get(AgentRun, state.run_id) || state.run

    if AgentRun.waiting?(run) do
      {:noreply, rearm(state, run)}
    else
      {:stop, :normal, %{state | run: run}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) when reason != :normal do
    Logger.error("[VibeAgents.Runs.Server] run #{state.run_id} loop task crashed: #{inspect(reason)}")
    run = update_run(state.run, %{status: "failed", error: "runtime_crash", finished_at: DateTime.utc_now()})
    Events.emit(run, "run.failed", %{"error" => "The runtime crashed running this turn.", "code" => "runtime_crash"})
    {:stop, :normal, cancel_timer(%{state | run: run})}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:run_timeout, state) do
    if state.task, do: Task.Supervisor.terminate_child(VibeAgents.TaskSupervisor, state.task.pid)

    run =
      update_run(state.run, %{
        status: "failed",
        error: "max_run_seconds exceeded",
        finished_at: DateTime.utc_now()
      })

    Events.emit(run, "run.failed", %{"error" => "This run exceeded its time budget.", "code" => "max_run_seconds"})
    {:stop, :normal, %{state | run: run}}
  end

  @impl true
  def handle_call({:await_decision, payload}, from, state) do
    persisted =
      update_run(state.run, %{
        status: payload.status,
        state: %{"messages" => payload.messages, "step" => payload.step || 0}
      })

    {:noreply, cancel_timer(%{state | run: persisted, awaiting: %{decision_id: payload.decision_id, from: from}})}
  end

  def handle_call({:decision, decision_map}, _from, state) do
    case Decisions.resolve(state.run.id, decision_map) do
      {:ok, resolved} ->
        run = update_run(state.run, %{status: "running"})
        waiting_caller = waiting_from(state.awaiting)
        state = %{state | run: run, awaiting: nil}

        state =
          if waiting_caller do
            GenServer.reply(waiting_caller, {:ok, resolved})
            state
          else
            start_task(state, fn -> Loop.resume(run, resolved) end, status: "running")
          end

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, attrs}, _from, state) do
    if state.task, do: Task.Supervisor.terminate_child(VibeAgents.TaskSupervisor, state.task.pid)

    run =
      update_run(state.run, %{
        status: "cancelled",
        error: attrs[:reason] || attrs["reason"] || "cancelled",
        finished_at: DateTime.utc_now()
      })

    Events.emit(run, "run.cancelled", %{"reason" => run.error})
    {:reply, :ok, %{state | run: run}, {:continue, :stop}}
  end

  @impl true
  def handle_continue(:stop, state), do: {:stop, :normal, state}

  defp waiting_from(%{from: from}), do: from
  defp waiting_from(_awaiting), do: nil

  defp rearm(state, run) do
    decision = Decisions.latest_pending(run.id)
    awaiting = if decision, do: %{decision_id: decision.id, from: nil}, else: nil
    %{state | run: run, task: nil, awaiting: awaiting}
  end

  defp start_task(state, fun, run_updates) do
    run = update_run(state.run, Map.new(run_updates))
    task = Task.Supervisor.async_nolink(VibeAgents.TaskSupervisor, fun)
    timer_ref = arm_timer()
    %{state | run: run, task: task, timer_ref: timer_ref}
  end

  defp arm_timer do
    seconds = Application.get_env(:vibe_agents, :max_run_seconds, 1200)
    Process.send_after(self(), :run_timeout, seconds * 1000)
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp update_run(run, attrs) do
    {:ok, updated} = run |> AgentRun.update_changeset(attrs) |> Repo.update()
    updated
  end
end
