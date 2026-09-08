defmodule Vibe.AgentSecretRotationTest do
  @moduledoc """
  Rotation has two jobs that pull in opposite directions: revoke a leaked key NOW, and roll a
  planned key without breaking live integrations.
  """

  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.Agents
  alias Vibe.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    owner = insert_user("rotation_owner")
    %{owner: owner, agent: insert_agent(owner)}
  end

  test "rotating without a grace window revokes the old secret immediately", %{
    owner: owner,
    agent: agent
  } do
    {:ok, agent, first} = Agents.rotate_secret(agent, owner.id)
    assert Agents.verify_secret(agent, first)

    {:ok, agent, second} = Agents.rotate_secret(agent, owner.id)

    assert Agents.verify_secret(agent, second)
    refute Agents.verify_secret(agent, first)
    assert agent.previous_secret_hash == nil
  end

  test "a grace window keeps the outgoing secret working until it expires", %{
    owner: owner,
    agent: agent
  } do
    {:ok, agent, old} = Agents.rotate_secret(agent, owner.id)
    {:ok, agent, new} = Agents.rotate_secret(agent, owner.id, grace_hours: 24)

    assert Agents.verify_secret(agent, new)
    assert Agents.verify_secret(agent, old), "outgoing secret must survive its grace window"

    expired =
      Repo.update!(
        Ecto.Changeset.change(agent,
          previous_secret_expires_at:
            DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
        )
      )

    refute Agents.verify_secret(expired, old)
    assert Agents.verify_secret(expired, new)
  end

  test "an immediate rotation cancels a grace window still in flight", %{
    owner: owner,
    agent: agent
  } do
    {:ok, agent, oldest} = Agents.rotate_secret(agent, owner.id)
    {:ok, agent, _middle} = Agents.rotate_secret(agent, owner.id, grace_hours: 24)
    assert Agents.verify_secret(agent, oldest)

    {:ok, agent, newest} = Agents.rotate_secret(agent, owner.id)

    refute Agents.verify_secret(agent, oldest)
    assert Agents.verify_secret(agent, newest)
    assert agent.previous_secret_expires_at == nil
  end

  test "grace hours are validated and capped", %{owner: owner, agent: agent} do
    assert {:error, :invalid_grace_hours} =
             Agents.rotate_secret(agent, owner.id, grace_hours: "soon")

    {:ok, capped, _secret} = Agents.rotate_secret(agent, owner.id, grace_hours: 10_000)
    limit = DateTime.utc_now() |> DateTime.add(169 * 3600, :second)
    assert DateTime.compare(capped.previous_secret_expires_at, limit) == :lt
  end

  test "a non-owner cannot rotate", %{agent: agent} do
    stranger = insert_user("rotation_stranger")
    assert {:error, :forbidden} = Agents.rotate_secret(agent, stranger.id)
  end

  defp insert_user(prefix) do
    suffix = System.unique_integer([:positive])

    Repo.insert!(%User{
      id: Ecto.UUID.generate(),
      username: "#{prefix}_#{suffix}",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}",
      is_agent: false
    })
  end

  defp insert_agent(owner) do
    shadow = insert_user("rotationagent")

    Repo.insert!(%Agent{
      owner_user_id: owner.id,
      agent_user_id: shadow.id,
      status: "published",
      display_name: "Rotator",
      enabled_tools: [],
      output_modes: ["text"],
      webhook_secret_hash: "hash",
      secret_hint: "hint"
    })
  end
end
