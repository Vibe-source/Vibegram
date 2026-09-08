defmodule Vibe.AgentAdminModeTest do
  @moduledoc """
  A custom agent's own runtime (Vibe.AI.StandaloneAgent) answers messages from ANYONE it can be
  DMed or added to a channel by.
  """

  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.Chat
  alias Vibe.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    %{owner: insert_user("policy_owner")}
  end

  describe "effective_agent_policy/3" do
    test "owner in the private owner<->agent DM gets admin_mode", %{owner: owner} do
      agent = insert_agent(owner, display_name: "Helper")
      {:ok, chat_id, _status} = Chat.ensure_dm_chat(owner.id, agent.agent_user_id)

      assert {:ok, %{admin_mode: true}} = Chat.effective_agent_policy(chat_id, agent, owner.id)
    end

    test "owner posting in a shared group never gets admin_mode", %{owner: owner} do
      agent = insert_agent(owner, display_name: "Helper")
      {:ok, room} = Chat.create_group(owner.id, "Team", [agent.agent_user_id], nil, nil)

      assert {:ok, %{admin_mode: false}} =
               Chat.effective_agent_policy(room.id, agent, owner.id)
    end

    test "a stranger DMing the agent never gets admin_mode", %{owner: owner} do
      agent = insert_agent(owner, display_name: "Helper")
      stranger = insert_user("stranger")
      {:ok, chat_id, _status} = Chat.ensure_dm_chat(stranger.id, agent.agent_user_id)

      assert {:ok, %{admin_mode: false}} =
               Chat.effective_agent_policy(chat_id, agent, stranger.id)
    end

    test "a stranger who happens to also own a DIFFERENT agent still gets no admin_mode here",
         %{owner: owner} do
      agent = insert_agent(owner, display_name: "Helper")
      other_owner = insert_user("other_owner")
      _unrelated_agent = insert_agent(other_owner, display_name: "Mine")

      {:ok, chat_id, _status} = Chat.ensure_dm_chat(other_owner.id, agent.agent_user_id)

      assert {:ok, %{admin_mode: false}} =
               Chat.effective_agent_policy(chat_id, agent, other_owner.id)
    end

    test "DM policy carries the same keys as the channel policy", %{owner: owner} do
      agent = insert_agent(owner, display_name: "Helper")
      {:ok, chat_id, _status} = Chat.ensure_dm_chat(owner.id, agent.agent_user_id)

      assert {:ok, policy} = Chat.effective_agent_policy(chat_id, agent, owner.id)

      for key <- [:enabled_tools, :output_modes, :trigger_config, :permissions, :admin_mode] do
        assert Map.has_key?(policy, key), "policy is missing #{inspect(key)}"
      end

      assert policy.permissions == %{}
    end
  end

  describe "Vibe.AI.Agent tool gating" do
    test "owner-management tools exist only in admin_mode" do
      admin_tools = Vibe.AI.Agent.effective_tool_names([], true)
      public_tools = Vibe.AI.Agent.effective_tool_names([], false)

      for tool <- ~w[list_my_agents get_current_agent_config update_current_agent_config check_agent_username] do
        assert tool in admin_tools, "expected #{tool} in admin_mode tool list"
        refute tool in public_tools, "#{tool} must never appear outside admin_mode"
      end
    end

    test "an agent's own configured tools are unaffected by admin_mode" do
      admin_tools = Vibe.AI.Agent.effective_tool_names(["search_music"], true)
      public_tools = Vibe.AI.Agent.effective_tool_names(["search_music"], false)

      assert "search_music" in admin_tools
      assert "search_music" in public_tools
    end
  end

  describe "Vibe.AI.PromptVariables secret flag" do
    test "a secret variable is blanked outside admin_mode, visible inside it" do
      agent = %{
        prompt_variables: [
          %{"name" => "internal_note", "value" => "top secret", "secret" => true},
          %{"name" => "store_hours", "value" => "9-5", "secret" => false}
        ]
      }

      admin_values = Vibe.AI.PromptVariables.effective_values(agent, admin_mode: true)
      public_values = Vibe.AI.PromptVariables.effective_values(agent, admin_mode: false)

      assert admin_values["internal_note"] == "top secret"
      assert public_values["internal_note"] == ""
      assert public_values["store_hours"] == "9-5"
    end

    test "render/3 never leaks a secret value into non-admin system prompt text" do
      agent = %{
        prompt_variables: [
          %{"name" => "internal_note", "value" => "top secret", "secret" => true}
        ]
      }

      rendered = Vibe.AI.PromptVariables.render("Note: {{internal_note}}", agent, admin_mode: false)

      refute rendered =~ "top secret"
    end
  end

  defp insert_user(prefix, attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    defaults = %{
      id: Ecto.UUID.generate(),
      username: "#{prefix}_#{suffix}",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}",
      is_agent: false
    }

    Repo.insert!(struct(User, Map.merge(defaults, Map.new(attrs))))
  end

  defp insert_agent(owner, attrs) do
    shadow = insert_user("adminmodeagent", %{is_agent: true})

    defaults = %{
      owner_user_id: owner.id,
      agent_user_id: shadow.id,
      status: "published",
      display_name: "Publisher",
      enabled_tools: [],
      output_modes: ["text"],
      webhook_secret_hash: "hash",
      secret_hint: "hint"
    }

    agent = Repo.insert!(struct(Agent, Map.merge(defaults, Map.new(attrs))))
    Repo.preload(agent, :agent_user)
  end
end
