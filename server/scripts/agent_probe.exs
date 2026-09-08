# Agent behaviour probe.

{:ok, _} = Application.ensure_all_started(:finch)
{:ok, _} = Finch.start_link(name: Vibe.Finch)
{:ok, _} = Task.Supervisor.start_link(name: Vibe.TaskSupervisor)

Logger.configure(level: :warning)

defmodule Probe do
  def trace_callback(agent) do
    fn event ->
      t = System.monotonic_time(:millisecond) - Agent.get(agent, & &1.t0)

      case event do
        %{type: :text, content: content} ->
          Agent.update(agent, fn s ->
            %{s | text: s.text <> content, text_events: s.text_events + 1}
          end)

          Agent.update(agent, fn s ->
            if s.beat_open? do
              s
            else
              log(t, "TEXT   ", "first delta of a beat")
              %{s | beat_open?: true}
            end
          end)

        %{type: :thinking, status: "running"} ->
          Agent.update(agent, fn s ->
            if s.thinking_open? do
              s
            else
              log(t, "THINK  ", "reasoning started")
              %{s | thinking_open?: true, thinking_turns: s.thinking_turns + 1}
            end
          end)

        %{type: :thinking, status: "done", tokens: tokens} ->
          log(t, "THINK  ", "reasoning done (~#{tokens} tokens)")
          Agent.update(agent, &%{&1 | thinking_open?: false})

        %{type: :progress, status: "running", tool: tool, label: label} ->
          input = Map.get(event, :input) || %{}
          log(t, "TOOL→  ", "#{tool}  #{inspect(label)}#{args(input)}")

          Agent.update(agent, fn s ->
            %{s | tools: s.tools ++ [tool], beat_open?: false}
          end)

        %{type: :progress, status: status, tool: tool, label: label} ->
          log(t, "TOOL←  ", "#{tool} #{status} #{inspect(label)}")
          Agent.update(agent, &%{&1 | beat_open?: false})

        %{type: :tool_result} = e ->
          log(t, "RESULT ", summarize_result(e))

        other ->
          log(t, "EVENT  ", inspect(Map.get(other, :type)))
      end

      :ok
    end
  end

  defp args(input) when map_size(input) == 0, do: ""

  defp args(input) do
    "  " <> (input |> Jason.encode!() |> String.slice(0, 220))
  end

  defp summarize_result(e) do
    e |> Map.get(:result, %{}) |> inspect() |> String.slice(0, 200)
  end

  defp log(t, tag, msg) do
    IO.puts(:stderr, "  #{String.pad_leading("#{t}", 6)}ms  #{tag} #{msg}")
  end
end

prompt =
  case System.argv() do
    [] -> "hey, I wanna plan for my workout, and I want it to be up to date"
    argv -> Enum.join(argv, " ")
  end

provider = System.get_env("PROBE_PROVIDER") || "anthropic"
model = System.get_env("PROBE_MODEL") || "claude-sonnet-5"
thinking = System.get_env("PROBE_THINKING") || "medium"

run = fn label, message, history ->
  IO.puts(:stderr, "\n" <> String.duplicate("═", 78))
  IO.puts(:stderr, "  #{label}: #{inspect(message)}")
  IO.puts(:stderr, "  #{provider} / #{model} / thinking=#{thinking}")
  IO.puts(:stderr, String.duplicate("═", 78))

  {:ok, agent} =
    Agent.start_link(fn ->
      %{
        t0: System.monotonic_time(:millisecond),
        text: "",
        text_events: 0,
        tools: [],
        thinking_turns: 0,
        thinking_open?: false,
        beat_open?: false
      }
    end)

  started = System.monotonic_time(:millisecond)

  result =
    Vibe.AI.Agent.stream_response(message, Probe.trace_callback(agent),
      history: history,
      user_id: nil,
      requester_user_id: nil,
      model_provider: provider,
      model_id: model,
      thinking_level: thinking,
      admin_mode: false
    )

  elapsed = System.monotonic_time(:millisecond) - started
  state = Agent.get(agent, & &1)

  {final_text, status} =
    case result do
      {:ok, text, s} -> {text, Map.get(s, :terminal_status, "completed")}
      {:ok, text} -> {text, "completed"}
      {:error, reason} -> {"<ERROR> #{inspect(reason)}", "error"}
    end

  IO.puts(:stderr, "\n" <> String.duplicate("─", 78))
  IO.puts(:stderr, "  VERDICT — #{label}")
  IO.puts(:stderr, "  wall time        : #{elapsed}ms")
  IO.puts(:stderr, "  status           : #{status}")
  IO.puts(:stderr, "  tool calls       : #{length(state.tools)}  #{inspect(state.tools)}")
  IO.puts(:stderr, "  distinct tools   : #{state.tools |> Enum.uniq() |> length()}")
  IO.puts(:stderr, "  reasoning blocks : #{state.thinking_turns}")
  IO.puts(:stderr, "  text deltas      : #{state.text_events}")
  IO.puts(:stderr, "  reply length     : #{String.length(final_text)} chars")
  IO.puts(:stderr, String.duplicate("─", 78))
  IO.puts(:stderr, final_text)
  IO.puts(:stderr, String.duplicate("─", 78) <> "\n")

  final_text
end

reply = run.("TURN 1", prompt, [])

case System.get_env("PROBE_FOLLOWUP") do
  followup when is_binary(followup) and followup != "" ->
    history = [
      %{"role" => "user", "content" => prompt},
      %{"role" => "assistant", "content" => reply}
    ]

    run.("TURN 2", followup, history)

  _ ->
    :ok
end
