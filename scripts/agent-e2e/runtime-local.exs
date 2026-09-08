import Ecto.Query

alias VibeAgents.Repo
alias VibeAgents.Schemas.AgentRunEvent

task =
  System.get_env("E2E_TASK") ||
    "Run `uname -a` on your computer and tell me the exact output. " <>
      "Then open https://example.com in your browser and tell me the page title."

tools = String.split(System.get_env("E2E_TOOLS") || "computer,research", ",", trim: true)

# E2E_TEAM="coderbot:Coder,publishbot:Publish manager".
participants =
  (System.get_env("E2E_TEAM") || "")
  |> String.split(",", trim: true)
  |> Enum.map(fn entry ->
    [username | rest] = String.split(entry, ":", parts: 2)

    %{
      "userId" => Ecto.UUID.generate(),
      "isAgent" => true,
      "isSelf" => false,
      "username" => String.trim(username),
      "name" => List.first(rest) || username,
      "role" => List.first(rest) || username
    }
  end)

request = %{
  "source" => "chat",
  "agentId" => Ecto.UUID.generate(),
  "agentUserId" => Ecto.UUID.generate(),
  "ownerUserId" => Ecto.UUID.generate(),
  "requesterUserId" => Ecto.UUID.generate(),
  "chatId" => "chat-" <> Ecto.UUID.generate(),
  "chatKind" => "dm",
  "input" => %{"text" => task, "attachments" => []},
  "agentProfile" => %{
    "displayName" => "E2E Bot",
    "username" => "e2ebot",
    "systemPrompt" => "You are a hands-on engineer. Do the work, then report what happened.",
    "modelProvider" => System.get_env("E2E_PROVIDER") || "openai",
    "modelId" => System.get_env("E2E_MODEL") || "gpt-5.6-luna",
    "thinkingLevel" => "medium",
    "enabledTools" => tools,
    "outputModes" => ["text"],
    "autonomyMode" => System.get_env("E2E_AUTONOMY") || "safe_auto",
    "approvalRules" => %{},
    "budgets" => %{"dailyCents" => nil, "monthlyCents" => nil},
    "adminMode" => false
  },
  "context" => %{"history" => [], "participants" => participants},
  "capabilities" => VibeContracts.ToolBundles.capabilities(tools)
}

{:ok, run} = VibeAgents.Runs.start(request)
IO.puts("run #{run.id} started · tools=#{inspect(tools)}\ntask: #{task}\n")

deadline = System.monotonic_time(:millisecond) + 300_000

wait = fn wait ->
  events =
    AgentRunEvent |> where([e], e.run_id == ^run.id) |> order_by([e], e.seq) |> Repo.all()

  done? = Enum.any?(events, &VibeContracts.RunEvent.terminal?(&1.kind))

  cond do
    done? -> events
    System.monotonic_time(:millisecond) > deadline -> events
    true -> (Process.sleep(2_000) && wait.(wait))
  end
end

events = wait.(wait)

for e <- events do
  detail =
    case e.kind do
      "run.text.delta" -> String.slice(e.payload["text"] || "", 0, 200)
      "run.tool.started" -> "#{e.payload["tool"]} #{inspect(e.payload["input"], limit: 6)}"
      "run.tool.completed" -> "#{e.payload["tool"]} -> #{String.slice(inspect(e.payload["result"], limit: 8), 0, 300)}"
      _ -> String.slice(inspect(e.payload, limit: 8), 0, 300)
    end

  IO.puts("[#{e.seq}] #{e.kind}  #{detail}")
end

text =
  events
  |> Enum.filter(&(&1.kind == "run.text.delta"))
  |> Enum.map_join("", &(&1.payload["text"] || ""))

tools_used =
  events |> Enum.filter(&(&1.kind == "run.tool.started")) |> Enum.map(& &1.payload["tool"]) |> Enum.uniq()

IO.puts("\n===== ANSWER =====\n#{text}\n")
IO.puts("tools used: #{inspect(tools_used)}")
IO.puts("terminal: #{inspect(Enum.find(events, &VibeContracts.RunEvent.terminal?(&1.kind)) |> then(&(&1 && &1.kind)))}")
