defmodule VibeAgents.RunsTest do
  use ExUnit.Case, async: false

  import VibeAgents.Test.Fixtures

  alias VibeAgents.Repo
  alias VibeAgents.Runs
  alias VibeAgents.Runs.{Decisions, Events}
  alias VibeAgents.Schemas.{AgentRun, AgentRunEvent, OutboxEvent}
  alias VibeAgents.Test.FakeCoreHTTP

  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(VibeAgents.Runs.Supervisor), is_pid(pid) do
      DynamicSupervisor.terminate_child(VibeAgents.Runs.Supervisor, pid)
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    FakeCoreHTTP.reset()
    Application.put_env(:vibe_agents, :kill_switch, false)
    Application.put_env(:vibe_agents, :fake_llm_script, [{:text, "Hello from the fake model."}])

    on_exit(fn ->
      Application.delete_env(:vibe_agents, :fake_llm_script)
      Application.put_env(:vibe_agents, :kill_switch, false)
    end)

    :ok
  end

  test "kill switch refuses new runs" do
    Application.put_env(:vibe_agents, :kill_switch, true)
    assert {:error, :kill_switch} = Runs.start(run_request())
  end

  test "idempotencyKey returns the same run" do
    req = run_request(%{"idempotencyKey" => "idem-" <> uuid()})
    assert {:ok, run1} = Runs.start(req)
    assert {:ok, run2} = Runs.start(req)
    assert run1.id == run2.id
  end

  test "a text-only turn completes, delivers text, and emits ordered events" do
    {:ok, run} = Runs.start(run_request())

    eventually(fn -> Repo.get(AgentRun, run.id).status == "completed" end)

    kinds = Repo.all(AgentRunEvent) |> Enum.filter(&(&1.run_id == run.id)) |> Enum.sort_by(& &1.seq) |> Enum.map(& &1.kind)
    assert kinds == ["run.started", "run.completed"]

    seqs = Repo.all(AgentRunEvent) |> Enum.filter(&(&1.run_id == run.id)) |> Enum.map(& &1.seq) |> Enum.sort()
    assert seqs == Enum.to_list(1..length(seqs))

    assert Repo.all(OutboxEvent) |> Enum.filter(&(&1.run_id == run.id)) |> length() == 2

    eventually(fn -> FakeCoreHTTP.calls_to("/deliveries") != [] end)
    [delivery] = FakeCoreHTTP.calls_to("/deliveries")
    assert [%{"text" => "Hello from the fake model."} | _] = delivery.body["outputs"]
  end

  test "ask_user ends the turn waiting and a decision resumes it" do
    Application.put_env(:vibe_agents, :fake_llm_script, [
      {:tool_use,
       [
         %{
           "id" => "call-1",
           "name" => "ask_user",
           "input" => %{
             "questions" => [
               %{
                 "question" => "Which colour?",
                 "header" => "Colour",
                 "options" => [%{"label" => "Red"}, %{"label" => "Blue"}]
               }
             ]
           }
         }
       ]},
      {:text, "Great, blue it is."}
    ])

    {:ok, run} = Runs.start(run_request())
    eventually(fn -> Repo.get(AgentRun, run.id).status == "waiting_ask" end)

    decision = eventually(fn -> Decisions.latest_pending(run.id) end)
    assert decision.kind == "ask"

    assert :ok =
             Runs.decide(run.id, %{
               "decisionId" => decision.id,
               "kind" => "ask",
               "outcome" => "answer",
               "answer" => %{"selections" => [%{"selected" => ["Blue"]}]},
               "actorUserId" => uuid()
             })

    eventually(fn -> Repo.get(AgentRun, run.id).status == "completed" end)
    assert {:error, :already_decided} = Decisions.resolve(run.id, %{"decisionId" => decision.id, "outcome" => "answer"})
  end

  test "cancel stops a queued/running run and emits run.cancelled" do
    Application.put_env(:vibe_agents, :fake_llm_script, [{:tool_use, [%{"id" => "c", "name" => "slow_tool", "input" => %{}}]}, {:text, "done"}])
    {:ok, run} = Runs.start(run_request())

    case Runs.cancel(run.id, %{reason: "user"}) do
      :ok ->
        eventually(fn -> Repo.get(AgentRun, run.id).status == "cancelled" end)
        assert Enum.any?(Repo.all(AgentRunEvent), &(&1.run_id == run.id and &1.kind == "run.cancelled"))

      {:error, :not_found} ->
        assert Repo.get(AgentRun, run.id).status in ["completed", "failed"]
    end
  end

  test "events are appended with strictly increasing seq" do
    run = insert_run!()
    {:ok, e1} = Events.emit(run, "run.progress", %{"label" => "a", "status" => "running"})
    {:ok, e2} = Events.emit(run, "run.progress", %{"label" => "b", "status" => "running"})
    assert e2["seq"] == e1["seq"] + 1
    assert e1["contract"] == "vibe.agentic.v1"
  end
end
