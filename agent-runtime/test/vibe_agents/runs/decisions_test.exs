defmodule VibeAgents.Runs.DecisionsTest do
  use ExUnit.Case, async: false

  import VibeAgents.Test.Fixtures

  alias VibeAgents.Repo
  alias VibeAgents.Runs.Decisions

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    %{run: insert_run!()}
  end

  test "pending → resolved exactly once", %{run: run} do
    {:ok, decision} = Decisions.create(%{run_id: run.id, kind: "approval", request: %{"title" => "Do it?"}})
    assert decision.status == "pending"

    assert {:ok, resolved} = Decisions.resolve(run.id, %{"decisionId" => decision.id, "outcome" => "approve", "actorUserId" => uuid()})
    assert resolved.status == "resolved" and resolved.outcome == "approve"
    assert {:error, :already_decided} = Decisions.resolve(run.id, %{"decisionId" => decision.id, "outcome" => "approve"})
  end

  test "a decision from another run is not found", %{run: run} do
    other = insert_run!()
    {:ok, decision} = Decisions.create(%{run_id: other.id, kind: "approval", request: %{}})
    assert {:error, :not_found} = Decisions.resolve(run.id, %{"decisionId" => decision.id, "outcome" => "approve"})
  end

  test "an expired decision cannot be resolved", %{run: run} do
    past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
    {:ok, decision} = Decisions.create(%{run_id: run.id, kind: "permission", request: %{}, expires_at: past})
    assert {:error, :expired} = Decisions.resolve(run.id, %{"decisionId" => decision.id, "outcome" => "grant"})
    assert Decisions.get(decision.id).status == "expired"
  end

  test "unknown ids are not found", %{run: run} do
    assert {:error, :not_found} = Decisions.resolve(run.id, %{"decisionId" => "nope"})
    assert {:error, :not_found} = Decisions.resolve(run.id, %{"decisionId" => uuid()})
  end
end
