defmodule Vibe.AI.AgentRuntimeFallbackTest do
  use ExUnit.Case, async: false

  alias Vibe.AI.AgentRuntime
  alias Vibe.AI.AgentRuntime.Config

  defmodule ProviderStub do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/claude" do
      Plug.Conn.send_resp(conn, 503, ~s({"error":"temporarily unavailable"}))
    end

    post "/v1/responses" do
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)

      if test_process = Application.get_env(:vibe, :agent_runtime_fallback_test_pid) do
        send(test_process, {:openai_request, Jason.decode!(request_body)})
      end

      body =
        [
          "data: ",
          Jason.encode!(%{
            "type" => "response.output_text.delta",
            "delta" => "Handled by GPT-5.6 Luna."
          }),
          "\n\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.completed",
            "response" => %{"status" => "completed"}
          }),
          "\n\n"
        ]
        |> IO.iodata_to_binary()

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  setup do
    environment_names = [
      "ANTHROPIC_API_KEY",
      "CLAUDE_API_KEY",
      "OPENAI_API_KEY",
      "OPENAI_AGENT_FALLBACK_MODEL",
      "OPENAI_AGENT_FALLBACK_REASONING_EFFORT"
    ]

    previous_environment = Map.new(environment_names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous_environment, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "falls back from a failed Claude request to the OpenAI Responses stream" do
    System.put_env("ANTHROPIC_API_KEY", "test-claude-key")
    System.put_env("OPENAI_API_KEY", "test-openai-key")
    System.delete_env("CLAUDE_API_KEY")
    System.put_env("OPENAI_AGENT_FALLBACK_MODEL", "gpt-5")
    System.delete_env("OPENAI_AGENT_FALLBACK_REASONING_EFFORT")

    previous_test_process = Application.get_env(:vibe, :agent_runtime_fallback_test_pid)
    Application.put_env(:vibe, :agent_runtime_fallback_test_pid, self())

    on_exit(fn ->
      if previous_test_process do
        Application.put_env(:vibe, :agent_runtime_fallback_test_pid, previous_test_process)
      else
        Application.delete_env(:vibe, :agent_runtime_fallback_test_pid)
      end
    end)

    ref = String.to_atom("agent_runtime_provider_#{System.unique_integer([:positive])}")
    {:ok, _pid} = Plug.Cowboy.http(ProviderStub, [], port: 0, ref: ref)
    port = :ranch.get_port(ref)

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

    test_process = self()

    assert {:ok, "Handled by GPT-5.6 Luna.", %{}} =
             AgentRuntime.run(
               [%{role: "user", content: "Hello"}],
               config(
                 claude_api_url: "http://127.0.0.1:#{port}/claude",
                 openai_responses_url: "http://127.0.0.1:#{port}/v1/responses",
                 callback: fn event -> send(test_process, {:agent_event, event}) end
               )
             )

    assert_receive {:agent_event, %{type: :text, content: "Handled by GPT-5.6 Luna."}}
    assert_receive {:openai_request, %{"model" => "gpt-5.6-luna"}}
  end

  test "builds the Responses payload with the GPT-5.6 low-cost model and function tools" do
    config =
      config(
        system_prompt: fn state -> "You are #{state.agent_name}." end,
        state: %{agent_name: "Vibe"},
        tools: [
          %{
            name: "ask_user",
            description: "Ask one blocking question.",
            input_schema: %{
              type: "object",
              properties: %{question: %{type: "string"}},
              required: ["question"]
            }
          }
        ]
      )

    payload =
      AgentRuntime.openai_request_payload(
        [
          %{
            role: "user",
            content: [
              %{type: "image", source: %{type: "url", url: "https://example.test/a.jpg"}},
              %{type: "text", text: "What is this?"}
            ]
          }
        ],
        config
      )

    assert payload["model"] == "gpt-5.6-luna"
    assert payload["instructions"] == "You are Vibe."
    assert payload["reasoning"] == %{"effort" => "medium", "summary" => "auto"}
    assert payload["stream"]
    refute payload["store"]

    assert payload["tools"] == [
             %{
               "type" => "function",
               "name" => "ask_user",
               "description" => "Ask one blocking question.",
               "parameters" => %{
                 type: "object",
                 properties: %{question: %{type: "string"}},
                 required: ["question"]
               }
             }
           ]

    assert payload["input"] == [
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "input_image", "image_url" => "https://example.test/a.jpg"},
                 %{"type" => "input_text", "text" => "What is this?"}
               ]
             }
           ]
  end

  test "preserves call IDs across an Anthropic-shaped tool round" do
    input =
      AgentRuntime.openai_input([
        %{role: "user", content: "Create a private channel."},
        %{
          role: "assistant",
          content: [
            %{type: "text", text: "I need one detail."},
            %{
              type: "tool_use",
              id: "call_42",
              name: "ask_user",
              input: %{question: "Who can join?"}
            }
          ]
        },
        %{
          role: "user",
          content: [
            %{
              type: "tool_result",
              tool_use_id: "call_42",
              content: ~s({"answer":"Invite only"})
            }
          ]
        }
      ])

    assert [
             %{"role" => "user", "content" => "Create a private channel."},
             %{"role" => "assistant", "content" => "I need one detail."},
             %{
               "type" => "function_call",
               "call_id" => "call_42",
               "name" => "ask_user",
               "arguments" => arguments
             },
             %{
               "type" => "function_call_output",
               "call_id" => "call_42",
               "output" => ~s({"answer":"Invite only"})
             }
           ] = input

    assert Jason.decode!(arguments) == %{"question" => "Who can join?"}
  end

  test "reconstructs streamed text and function arguments as separate output parts" do
    acc = openai_stream_acc()

    {acc, "Checking first. "} =
      AgentRuntime.reduce_openai_stream_event(acc, %{
        "type" => "response.output_text.delta",
        "delta" => "Checking first. "
      })

    {acc, nil} =
      AgentRuntime.reduce_openai_stream_event(acc, %{
        "type" => "response.output_item.added",
        "output_index" => 1,
        "item" => %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => "call_99",
          "name" => "ask_user",
          "arguments" => ""
        }
      })

    {acc, nil} =
      AgentRuntime.reduce_openai_stream_event(acc, %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "fc_1",
        "output_index" => 1,
        "delta" => ~s({"question":)
      })

    {acc, nil} =
      AgentRuntime.reduce_openai_stream_event(acc, %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "fc_1",
        "output_index" => 1,
        "delta" => ~s("Which type?"})
      })

    {acc, nil} =
      AgentRuntime.reduce_openai_stream_event(acc, %{"type" => "response.completed"})

    assert {:tool_use, [tool], partial_response, "Checking first. "} =
             AgentRuntime.finalize_openai_response(acc)

    assert tool == %{
             "id" => "call_99",
             "name" => "ask_user",
             "input" => %{"question" => "Which type?"}
           }

    assert partial_response == [
             %{"type" => "text", "text" => "Checking first. "},
             %{
               "type" => "tool_use",
               "id" => "call_99",
               "name" => "ask_user",
               "input" => %{"question" => "Which type?"}
             }
           ]
  end

  defp config(overrides) do
    struct!(
      Config,
      Keyword.merge(
        [
          model: "claude-haiku",
          system_prompt: "You are Vibe.",
          tools: [],
          execute_tools: fn _calls, state, _callback -> {[], state} end
        ],
        overrides
      )
    )
  end

  defp openai_stream_acc do
    %{
      status: 200,
      text: "",
      tool_calls: %{},
      tool_order: [],
      completed?: false,
      error: nil,
      buffer: ""
    }
  end
end
