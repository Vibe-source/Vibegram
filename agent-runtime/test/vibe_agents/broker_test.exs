defmodule VibeAgents.BrokerTest do
  use ExUnit.Case, async: true

  alias VibeAgents.Broker

  defp run(mode, rules \\ %{}) do
    %{"agent_profile" => %{"autonomyMode" => mode, "approvalRules" => rules}}
  end

  describe "risk classes" do
    test "read tools always run in every mode" do
      for mode <- ~w(full_auto safe_auto approval_required manual draft_first),
          tool <- ~w(search_google read_url computer_read_file browser_screenshot recall) do
        assert :run == Broker.authorize(run(mode), tool, %{}), "#{tool} in #{mode}"
      end
    end

    test "write_local runs in full/safe auto and needs approval otherwise" do
      assert :run == Broker.authorize(run("full_auto"), "computer_write_file", %{"path" => "/home/agent/a"})
      assert :run == Broker.authorize(run("safe_auto"), "browser_open", %{"url" => "https://x"})
      assert {:approval, %{"risk" => "write_local"}} = Broker.authorize(run("approval_required"), "browser_open", %{})
      assert {:approval, _} = Broker.authorize(run("manual"), "remember", %{})
      assert {:approval, _} = Broker.authorize(run("draft_first"), "computer_write_file", %{})
    end

    test "external_effect needs approval unless full_auto allowlists the tool" do
      cmd = %{"command" => "git push origin main"}
      assert {:approval, %{"risk" => "external_effect"}} = Broker.authorize(run("safe_auto"), "computer_run", cmd)
      assert {:approval, _} = Broker.authorize(run("full_auto"), "computer_run", cmd)
      assert :run == Broker.authorize(run("full_auto", %{"allow" => ["computer_run"]}), "computer_run", cmd)
    end

    test "browser actions that look like purchases or submits are external effects" do
      assert :external_effect == Broker.risk_class("browser_act", %{"kind" => "click", "text" => "Buy now"})
      assert :external_effect == Broker.risk_class("browser_act", %{"kind" => "click", "selector" => "#checkout"})
      assert :write_local == Broker.risk_class("browser_act", %{"kind" => "scroll"})
    end

    test "credential-shaped browser actions always ask the human" do
      assert {:ask, [question | _]} =
               Broker.authorize(run("full_auto"), "browser_act", %{"kind" => "type", "selector" => "#password"})

      assert question["header"] == "Credential"
    end

    test "request_approval is always an explicit approval with the model's title" do
      assert {:approval, %{"title" => "Send the invoice?", "risk" => "spend"}} =
               Broker.authorize(run("full_auto"), "request_approval", %{"title" => "Send the invoice?", "risk" => "spend"})
    end

    test "unknown autonomy mode defaults to approval_required" do
      assert {:approval, _} = Broker.authorize(%{"agent_profile" => %{}}, "computer_write_file", %{})
    end
  end

  describe "capabilities" do
    test "computer and browser tools need their capability; others need none" do
      assert "computer" == Broker.required_capability("computer_run")
      assert "browser" == Broker.required_capability("browser_act")
      assert nil == Broker.required_capability("search_google")
    end

    test "only full/safe auto auto-grant capability use" do
      assert Broker.auto_grant_capability?(run("full_auto"))
      assert Broker.auto_grant_capability?(run("safe_auto"))
      refute Broker.auto_grant_capability?(run("approval_required"))
    end
  end
end
