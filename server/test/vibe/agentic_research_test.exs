defmodule Vibe.AI.AgenticResearchTest do
  @moduledoc """
  Guards the two properties that make the agent agentic, both of which regressed silently
  before they were tested:
  """

  use ExUnit.Case, async: false

  alias Vibe.AI.Agent
  alias Vibe.AI.AgenticPolicy
  alias Vibe.AI.AgentRuntime
  alias Vibe.AI.AgentRuntime.Config
  alias Vibe.AI.GroupAgent
  alias Vibe.AI.Tools.Research

  describe "policy reaches every agent surface" do
    test "the research policy appears only when the agent can research" do
      with_search = AgenticPolicy.prompt_guidance(["search_google"])
      without_search = AgenticPolicy.prompt_guidance(["search_music"])

      assert with_search =~ "search finds candidates"
      assert with_search =~ "THEN CHECK YOURSELF"
      refute without_search =~ "search finds candidates"
    end

    test "the turn shape is unconditional — beats are not a research-only behaviour" do
      assert AgenticPolicy.prompt_guidance([]) =~ "beat → tool round"
      assert AgenticPolicy.prompt_guidance(["search_google"]) =~ "beat → tool round"
    end

    test "the built-in assistant prompt carries the shared policy, not a private copy" do
      prompt = Agent.default_system_prompt()

      for line <- policy_lines(AgenticPolicy.turn_shape()) do
        assert String.contains?(prompt, line), "built-in prompt lost turn-shape line: #{line}"
      end

      for line <- policy_lines(AgenticPolicy.research()) do
        assert String.contains?(prompt, line), "built-in prompt lost research line: #{line}"
      end
    end

    defp policy_lines(section) do
      section
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(String.length(&1) > 30))
    end
  end

  describe "reading is granted to anything that can search" do
    test "the built-in tool filter grants read_url alongside search_google" do
      names = Agent.effective_tool_names(["search_google"], false)

      assert "search_google" in names
      assert "read_url" in names
    end

    test "an agent that cannot search does not get a reader" do
      refute "read_url" in Agent.effective_tool_names(["search_music"], false)
    end

    test "group agents get the same grant" do
      tools = GroupAgent.normalize_enabled_tools(["search_google"])

      assert "search_google" in tools
      assert "read_url" in tools
    end
  end

  describe "read_url refuses to be an SSRF primitive" do
    test "non-http schemes are rejected" do
      assert %{error: message} = Research.read(%{"url" => "file:///etc/passwd"})
      assert message =~ "http(s)"
    end

    test "link-local and loopback addresses are rejected" do
      for url <- [
            "http://169.254.169.254/latest/meta-data/",
            "http://127.0.0.1:4000/",
            "http://10.0.0.5/",
            "http://192.168.1.1/"
          ] do
        assert %{error: message} = Research.read(%{"url" => url}),
               "#{url} was not rejected"

        assert message =~ "not publicly routable"
      end
    end

    test "a missing url is an error, not a crash" do
      assert %{error: _} = Research.read(%{})
      assert %{error: _} = Research.read(%{"url" => ""})
    end
  end

  describe "provider fallback preserves the tier the user paid for" do
    defmodule ProviderStub do
      use Plug.Router

      plug(:match)
      plug(:dispatch)

      post "/claude" do
        Plug.Conn.send_resp(conn, 400, ~s({"error":{"message":"credit balance is too low"}}))
      end

      post "/v1/responses" do
        {:ok, request_body, conn} = Plug.Conn.read_body(conn)

        if pid = Application.get_env(:vibe, :agentic_research_test_pid) do
          send(pid, {:openai_request, Jason.decode!(request_body)})
        end

        body =
          [
            "data: ",
            Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "ok"}),
            "\n\n",
            "data: ",
            Jason.encode!(%{"type" => "response.completed", "response" => %{"status" => "completed"}}),
            "\n\n"
          ]
          |> IO.iodata_to_binary()

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end
    end

    setup do
      names = [
        "ANTHROPIC_API_KEY",
        "CLAUDE_API_KEY",
        "OPENAI_API_KEY",
        "OPENAI_AGENT_FALLBACK_MODEL",
        "OPENAI_AGENT_FALLBACK_REASONING_EFFORT"
      ]

      previous = Map.new(names, &{&1, System.get_env(&1)})
      previous_pid = Application.get_env(:vibe, :agentic_research_test_pid)

      System.put_env("ANTHROPIC_API_KEY", "test-claude-key")
      System.put_env("OPENAI_API_KEY", "test-openai-key")
      System.delete_env("CLAUDE_API_KEY")
      System.delete_env("OPENAI_AGENT_FALLBACK_MODEL")
      System.delete_env("OPENAI_AGENT_FALLBACK_REASONING_EFFORT")
      Application.put_env(:vibe, :agentic_research_test_pid, self())

      ref = String.to_atom("agentic_research_stub_#{System.unique_integer([:positive])}")
      {:ok, _pid} = Plug.Cowboy.http(ProviderStub, [], port: 0, ref: ref)
      port = :ranch.get_port(ref)

      on_exit(fn ->
        Plug.Cowboy.shutdown(ref)

        Enum.each(previous, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)

        if previous_pid do
          Application.put_env(:vibe, :agentic_research_test_pid, previous_pid)
        else
          Application.delete_env(:vibe, :agentic_research_test_pid)
        end
      end)

      {:ok, port: port}
    end

    test "a max-tier Claude request falls back to a max-tier OpenAI model at the same effort",
         %{port: port} do
      assert {:ok, "ok", state} = run_fallback(port, "claude-fable-5", "xhigh")

      assert_receive {:openai_request, %{"model" => "gpt-5.6-sol", "reasoning" => reasoning}}
      assert reasoning["effort"] == "xhigh"

      assert state.served_model == "gpt-5.6-sol"
      assert state.requested_model == "claude-fable-5"
      assert state.substituted? == true
    end

    test "a balanced Claude request falls back to the balanced OpenAI model", %{port: port} do
      assert {:ok, "ok", _state} = run_fallback(port, "claude-sonnet-5", "high")

      assert_receive {:openai_request, %{"model" => "gpt-5.6-terra", "reasoning" => reasoning}}
      assert reasoning["effort"] == "high"
    end

    test "effort is clamped to what the substitute actually supports", %{port: port} do
      assert {:ok, "ok", _state} = run_fallback(port, "claude-haiku-4-5-20251001", "max")

      assert_receive {:openai_request, %{"model" => "gpt-5.6-luna", "reasoning" => reasoning}}
      assert reasoning["effort"] == "high"
    end

    test "group agents can borrow the OpenAI path in Anthropic's decoded shape", %{port: port} do
      config = %Config{
        model: "claude-haiku-4-5-20251001",
        system_prompt: "You are a group assistant.",
        tools: [],
        execute_tools: fn _calls, state, _callback -> {[], state} end,
        openai_responses_url: "http://127.0.0.1:#{port}/v1/responses"
      }

      assert {:ok, parsed} =
               AgentRuntime.anthropic_shaped_openai_completion(
                 [%{role: "user", content: "Hello"}],
                 config
               )

      assert parsed["stop_reason"] == "end_turn"
      assert [%{"type" => "text", "text" => "ok"}] = parsed["content"]
    end

    test "an explicit operator pin still wins over tier mapping", %{port: port} do
      System.put_env("OPENAI_AGENT_FALLBACK_MODEL", "gpt-5.6-luna")

      assert {:ok, "ok", _state} = run_fallback(port, "claude-fable-5", "xhigh")

      assert_receive {:openai_request, %{"model" => "gpt-5.6-luna"}}
    end

    defp run_fallback(port, model, thinking_level) do
      AgentRuntime.run(
        [%{role: "user", content: "Hello"}],
        %Config{
          model: model,
          thinking_level: thinking_level,
          system_prompt: "You are a test.",
          tools: [],
          execute_tools: fn _calls, state, _callback -> {[], state} end,
          claude_api_url: "http://127.0.0.1:#{port}/claude",
          openai_responses_url: "http://127.0.0.1:#{port}/v1/responses"
        }
      )
    end
  end
end
