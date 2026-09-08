defmodule Vibe.AgentDecisionsTest do
  @moduledoc """
  Sender-declared decision actions on agent events: round-trip, one-shot race,
  auth, cross-decision token isolation, and expiry.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.AgentApprovalTask
  alias Vibe.AgentDecisionAction
  alias Vibe.AgentDeliveryEvent
  alias Vibe.Agents
  alias Vibe.AI.AgentDecisions
  alias Vibe.AI.AgentEventRuntime
  alias Vibe.Chat
  alias Vibe.Chat.Message
  alias Vibe.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    owner = insert_user("decision_owner")
    agent = insert_agent(owner, callback_url: "https://8.8.8.8/decision-callback")
    {:ok, agent, secret} = Agents.rotate_secret(agent, owner.id)
    {:ok, chat_id, _} = Chat.ensure_dm_chat(owner.id, agent.agent_user_id)

    agent =
      agent
      |> Ecto.Changeset.change(default_destination_chat_id: chat_id, status: "published")
      |> Repo.update!()
      |> Repo.preload(:agent_user)

    %{owner: owner, agent: agent, secret: secret, chat_id: chat_id}
  end

  describe "normalize_declaration/1" do
    test "absent or empty actions are a no-op" do
      assert {:ok, nil} = AgentDecisions.normalize_declaration(%{})
      assert {:ok, nil} = AgentDecisions.normalize_declaration(%{"actions" => []})
    end

    test "accepts a bounded valid declaration" do
      assert {:ok, decl} =
               AgentDecisions.normalize_declaration(%{
                 "actions" => [
                   %{"id" => "approve", "label" => "Approve", "style" => "primary"},
                   %{
                     "id" => "reject",
                     "label" => "Reject",
                     "style" => "destructive",
                     "confirm" => "Reject this?"
                   }
                 ],
                 "actionMode" => "single",
                 "expiresAt" =>
                   DateTime.utc_now()
                   |> DateTime.add(3600, :second)
                   |> DateTime.to_iso8601()
               })

      assert decl.action_mode == "single"
      assert length(decl.actions) == 2
      assert hd(decl.actions).id == "approve"
    end

    test "rejects bad ids, styles, and oversize sets" do
      assert {:error, :invalid_action_id} =
               AgentDecisions.normalize_declaration(%{
                 "actions" => [%{"id" => "YES!", "label" => "Ok"}]
               })

      assert {:error, :invalid_action_style} =
               AgentDecisions.normalize_declaration(%{
                 "actions" => [%{"id" => "ok", "label" => "Ok", "style" => "neon"}]
               })

      too_many =
        for i <- 1..9, do: %{"id" => "a#{i}", "label" => "A#{i}"}

      assert {:error, :too_many_actions} =
               AgentDecisions.normalize_declaration(%{"actions" => too_many})
    end
  end

  describe "ingest round trip" do
    test "declared actions create a pending decision message with tokens", ctx do
      assert {:ok, result} = ingest_decision(ctx)

      assert result.decision == "approval_required"
      assert is_binary(result.approvalTaskId)

      task =
        AgentApprovalTask
        |> Repo.get!(result.approvalTaskId)
        |> Repo.preload(:decision_actions)

      assert task.source == "declared"
      assert task.status == "pending"
      assert task.action_mode == "single"
      assert is_binary(task.message_id)
      assert length(task.decision_actions) == 2

      message = Repo.get!(Message, task.message_id)
      service = message.metadata["service"]
      assert service["kind"] == "decision"
      assert service["status"] == "pending"

      actions = get_in(service, ["decision", "actions"])
      assert length(actions) == 2

      assert Enum.all?(actions, fn a ->
               is_binary(a["token"]) and String.starts_with?(a["token"], "vat_")
             end)

      for action <- task.decision_actions do
        refute Enum.any?(actions, fn a ->
                 hash =
                   :crypto.hash(:sha256, a["token"]) |> Base.encode16(case: :lower)

                 hash == action.token_hash and a["token"] == action.token_hash
               end)

        assert byte_size(action.token_hash) == 64
      end
    end
  end

  describe "respond/2" do
    test "owner can claim a token and the message settles without live buttons", ctx do
      {:ok, result} = ingest_decision(ctx)
      {task, tokens} = load_task_and_tokens(result.approvalTaskId)
      approve_token = tokens["approve"]

      assert {:ok, claim} = AgentDecisions.respond(ctx.owner.id, approve_token)
      assert claim.action.action_id == "approve"
      assert claim.task.status == "approved"
      assert claim.task.chosen_action_id == "approve"

      message = Repo.get!(Message, task.message_id)
      service = message.metadata["service"]
      assert service["status"] == "decided"
      assert get_in(service, ["decision", "actions"]) == []
      assert get_in(service, ["decision", "chosen", "actionId"]) == "approve"

      delivery =
        Repo.one(
          from(d in AgentDeliveryEvent,
            where: d.agent_id == ^ctx.agent.id and d.event_type == "decision.action",
            order_by: [desc: d.inserted_at],
            limit: 1
          )
        )

      assert delivery
      assert delivery.target_url == ctx.agent.callback_url
      assert delivery.request_body["actionId"] == "approve"
      assert delivery.request_body["type"] == "decision.action"
      assert delivery.request_body["data"]["service"] == "api-gateway"
      assert delivery.request_body["data"]["version"] == "v2.4.1"
      assert delivery.request_body["sourceEventId"]
      assert delivery.request_body["threadKey"]
    end

    test "one-shot race: exactly one of two concurrent claims wins", ctx do
      {:ok, result} = ingest_decision(ctx)
      {_task, tokens} = load_task_and_tokens(result.approvalTaskId)
      token = tokens["approve"]

      parent = self()

      tasks =
        for i <- 1..2 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            result = AgentDecisions.respond(ctx.owner.id, token)
            {i, result}
          end)
        end

      outcomes = Task.await_many(tasks, 5_000) |> Enum.map(&elem(&1, 1))

      wins = Enum.filter(outcomes, &match?({:ok, _}, &1))
      losses = Enum.filter(outcomes, &match?({:error, :already_decided}, &1))

      assert length(wins) == 1
      assert length(losses) == 1

      task = Repo.get!(AgentApprovalTask, result.approvalTaskId)
      assert task.status == "approved"

      chosen =
        Repo.all(
          from(a in AgentDecisionAction, where: a.task_id == ^task.id and a.status == "chosen")
        )

      assert length(chosen) == 1
    end

    test "unauthorized responder is rejected", ctx do
      {:ok, result} = ingest_decision(ctx)
      {_task, tokens} = load_task_and_tokens(result.approvalTaskId)
      stranger = insert_user("decision_stranger")

      assert {:error, :forbidden} = AgentDecisions.respond(stranger.id, tokens["approve"])

      task = Repo.get!(AgentApprovalTask, result.approvalTaskId)
      assert task.status == "pending"
    end

    test "a token from one decision is rejected against another", ctx do
      {:ok, first} = ingest_decision(ctx, event_id: "evt-a")
      {:ok, second} = ingest_decision(ctx, event_id: "evt-b")

      {_t1, tokens1} = load_task_and_tokens(first.approvalTaskId)
      {_t2, tokens2} = load_task_and_tokens(second.approvalTaskId)

      assert {:ok, _} = AgentDecisions.respond(ctx.owner.id, tokens1["approve"])

      assert {:error, :already_decided} = AgentDecisions.respond(ctx.owner.id, tokens1["reject"])
      assert {:ok, claim} = AgentDecisions.respond(ctx.owner.id, tokens2["approve"])
      assert claim.task.id == second.approvalTaskId
    end

    test "expired pending sets are closed and tokens refuse", ctx do
      {:ok, result} = ingest_decision(ctx)
      task = Repo.get!(AgentApprovalTask, result.approvalTaskId)
      {_task, tokens} = load_task_and_tokens(task.id)

      past =
        DateTime.utc_now()
        |> DateTime.add(-60, :second)
        |> DateTime.truncate(:second)

      task
      |> Ecto.Changeset.change(expires_at: past)
      |> Repo.update!()

      assert 1 == AgentDecisions.expire_due_tasks()

      task = Repo.get!(AgentApprovalTask, task.id)
      assert task.status == "expired"

      message = Repo.get!(Message, task.message_id)
      assert message.metadata["service"]["status"] == "expired"
      assert get_in(message.metadata, ["service", "decision", "actions"]) == []

      assert {:error, :already_decided} = AgentDecisions.respond(ctx.owner.id, tokens["approve"])
    end
  end


  defp ingest_decision(ctx, opts \\ []) do
    event_id = Keyword.get(opts, :event_id, "evt-#{System.unique_integer([:positive])}")

    AgentEventRuntime.ingest(
      ctx.agent,
      %{
        "eventType" => "deploy.requested",
        "eventId" => event_id,
        "threadKey" => "deploy:#{event_id}",
        "title" => "Deploy api-gateway v2.4.1?",
        "body" => "12 commits, 3 migrations.",
        "destinationChatId" => ctx.chat_id,
        "data" => %{
          "service" => "api-gateway",
          "version" => "v2.4.1",
          "request_id" => "req-#{event_id}"
        },
        "actions" => [
          %{"id" => "approve", "label" => "Approve", "style" => "primary"},
          %{
            "id" => "reject",
            "label" => "Reject",
            "style" => "destructive",
            "confirm" => "Reject this deploy?"
          }
        ],
        "actionMode" => "single",
        "expiresAt" => DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      },
      secret: ctx.secret
    )
  end

  defp load_task_and_tokens(task_id) do
    task = Repo.get!(AgentApprovalTask, task_id)
    message = Repo.get!(Message, task.message_id)
    actions = get_in(message.metadata, ["service", "decision", "actions"]) || []

    tokens =
      Map.new(actions, fn a ->
        {a["id"], a["token"]}
      end)

    {task, tokens}
  end

  defp insert_user(prefix, attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    Repo.insert!(
      struct(
        %User{
          id: Ecto.UUID.generate(),
          username: "#{prefix}_#{suffix}",
          password_hash: "hash",
          public_key: "key",
          device_id: "device-#{suffix}",
          is_agent: false,
          name: String.capitalize(prefix)
        },
        attrs
      )
    )
  end

  defp insert_agent(owner, attrs) do
    shadow = insert_user("decisionagent", %{is_agent: true})

    defaults = %{
      owner_user_id: owner.id,
      agent_user_id: shadow.id,
      status: "published",
      display_name: "Decision Bot",
      enabled_tools: [],
      output_modes: ["text"],
      webhook_secret_hash: "hash",
      secret_hint: "hint",
      callback_url: attrs[:callback_url]
    }

    Repo.insert!(struct(Agent, Map.merge(defaults, Map.new(attrs))))
    |> Repo.preload(:agent_user)
  end
end
