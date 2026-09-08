defmodule Vibe.AgentRoutinesTest do
  @moduledoc "Routine create guards, claim_due locking, and the failure counter."

  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.AgentRoutine
  alias Vibe.AgentRoutines
  alias Vibe.Chat
  alias Vibe.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    owner = insert_user("routine_owner")
    agent = insert_agent(owner)
    {:ok, chat_id, _} = Chat.ensure_dm_chat(owner.id, agent.agent_user_id)
    %{owner: owner, agent: agent, chat_id: chat_id}
  end

  test "create rejects an unpublished agent", %{owner: owner, agent: agent, chat_id: chat_id} do
    draft = %{agent | status: "draft"}

    assert AgentRoutines.create(owner.id, draft, %{chat_id: chat_id, prompt: "hi", every_minutes: 30}) ==
             {:error, :agent_not_published}
  end

  test "create rejects a chat the owner/agent is not in", %{owner: owner, agent: agent} do
    other = insert_user("routine_other")
    stranger = insert_user("routine_stranger")
    {:ok, other_chat_id, _} = Chat.ensure_dm_chat(other.id, stranger.id)

    assert AgentRoutines.create(owner.id, agent, %{chat_id: other_chat_id, prompt: "hi", every_minutes: 30}) ==
             {:error, :not_in_chat}
  end

  test "create enforces the per-owner routine limit", %{owner: owner, agent: agent, chat_id: chat_id} do
    Application.put_env(:vibe, :agent_routines_max_per_owner, 1)
    on_exit(fn -> Application.delete_env(:vibe, :agent_routines_max_per_owner) end)

    assert {:ok, _} = AgentRoutines.create(owner.id, agent, %{chat_id: chat_id, prompt: "one", every_minutes: 30})

    assert AgentRoutines.create(owner.id, agent, %{chat_id: chat_id, prompt: "two", every_minutes: 30}) ==
             {:error, :routine_limit}
  end

  test "create sets next_trigger_at = now + every_minutes", %{owner: owner, agent: agent, chat_id: chat_id} do
    before_create = DateTime.utc_now()
    assert {:ok, routine} = AgentRoutines.create(owner.id, agent, %{chat_id: chat_id, prompt: "hi", every_minutes: 30})

    assert DateTime.diff(routine.next_trigger_at, before_create, :second) in 1750..1810
  end

  test "claim_due advances next_trigger_at and only claims due+active routines", %{
    owner: owner,
    agent: agent,
    chat_id: chat_id
  } do
    {:ok, due} = AgentRoutines.create(owner.id, agent, %{chat_id: chat_id, prompt: "due", every_minutes: 15})
    {:ok, future} = AgentRoutines.create(owner.id, agent, %{chat_id: chat_id, prompt: "future", every_minutes: 15})
    {:ok, paused} = AgentRoutines.create(owner.id, agent, %{chat_id: chat_id, prompt: "paused", every_minutes: 15})

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    force_due!(due, DateTime.add(now, -60, :second))
    force_due!(paused, DateTime.add(now, -60, :second), "paused")

    assert {:ok, claimed} = AgentRoutines.claim_due(10)
    assert Enum.map(claimed, & &1.id) == [due.id]

    [claimed_routine] = claimed
    assert claimed_routine.last_status == "running"
    assert DateTime.compare(claimed_routine.next_trigger_at, now) == :gt
    assert claimed_routine.agent.id == agent.id

    reloaded_future = Repo.get!(AgentRoutine, future.id)
    refute reloaded_future.last_status == "running"
  end

  test "complete: failed increments the counter and disables at the configured max", %{
    owner: owner,
    agent: agent,
    chat_id: chat_id
  } do
    Application.put_env(:vibe, :agent_routine_max_failures, 2)
    on_exit(fn -> Application.delete_env(:vibe, :agent_routine_max_failures) end)

    {:ok, routine} = AgentRoutines.create(owner.id, agent, %{chat_id: chat_id, prompt: "hi", every_minutes: 30})

    {:ok, once} = AgentRoutines.complete(routine.id, "failed", "boom")
    assert once.consecutive_failures == 1
    assert once.status == "active"

    {:ok, twice} = AgentRoutines.complete(routine.id, "failed", "boom again")
    assert twice.consecutive_failures == 2
    assert twice.status == "disabled_failures"
  end

  test "complete: skipped_credits leaves the failure counter untouched", %{
    owner: owner,
    agent: agent,
    chat_id: chat_id
  } do
    {:ok, routine} = AgentRoutines.create(owner.id, agent, %{chat_id: chat_id, prompt: "hi", every_minutes: 30})
    {:ok, failed_once} = AgentRoutines.complete(routine.id, "failed", "boom")
    assert failed_once.consecutive_failures == 1

    {:ok, skipped} = AgentRoutines.complete(routine.id, "skipped_credits", "no credits")
    assert skipped.consecutive_failures == 1
    assert skipped.last_status == "skipped_credits"
  end

  test "complete: completed resets the failure counter", %{owner: owner, agent: agent, chat_id: chat_id} do
    {:ok, routine} = AgentRoutines.create(owner.id, agent, %{chat_id: chat_id, prompt: "hi", every_minutes: 30})
    {:ok, _} = AgentRoutines.complete(routine.id, "failed", "boom")
    {:ok, completed} = AgentRoutines.complete(routine.id, "completed")
    assert completed.consecutive_failures == 0
    assert completed.last_status == "completed"
  end

  defp force_due!(routine, next_trigger_at, status \\ "active") do
    routine
    |> AgentRoutine.changeset(%{"next_trigger_at" => next_trigger_at, "status" => status})
    |> Repo.update!()
  end

  defp insert_user(prefix) do
    suffix = System.unique_integer([:positive])

    Repo.insert!(%User{
      id: Ecto.UUID.generate(),
      username: "#{prefix}_#{suffix}",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}",
      name: "Routine"
    })
  end

  defp insert_agent(owner) do
    shadow =
      Repo.insert!(%User{
        id: Ecto.UUID.generate(),
        username: "routineagent_#{System.unique_integer([:positive])}",
        password_hash: "hash",
        public_key: "key",
        device_id: "d",
        is_agent: true,
        name: "Bot"
      })

    Repo.insert!(%Agent{
      owner_user_id: owner.id,
      agent_user_id: shadow.id,
      status: "published",
      display_name: "Routine Bot",
      enabled_tools: [],
      output_modes: ["text"],
      webhook_secret_hash: "hash",
      secret_hint: "hint"
    })
    |> Repo.preload(:agent_user)
  end
end
