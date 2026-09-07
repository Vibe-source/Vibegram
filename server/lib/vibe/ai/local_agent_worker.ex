defmodule Vibe.AI.LocalAgentWorker do
  @moduledoc false

  require Logger
  import Ecto.Query

  alias Vibe.AgentBridge
  alias Vibe.Badges
  alias Vibe.Chat
  alias Vibe.Chat.AgentMessageCrypto
  alias Vibe.Chat.GroupAgentMemory
  alias Vibe.Notifications
  alias Vibe.Repo
  alias Vibe.AI.TeamRun

  # How many recent shared-thread turns to inject as collaboration context.
  @group_context_messages 12

  @agent_user_id Vibe.AI.GroupAgent.agent_user_id()
  # Distinct agent user identities so @claude / @codex / @grok / @agy are.
  @claude_agent_user_id "11111111-1111-1111-1111-111111111111"
  @codex_agent_user_id "22222222-2222-2222-2222-222222222222"
  @grok_agent_user_id "33333333-3333-3333-3333-333333333333"
  @agy_agent_user_id "44444444-4444-4444-4444-444444444444"
  # Role agents: own identity, own model, run their CLI on the server (no bridge).
  @boss_agent_user_id "55555555-5555-5555-5555-555555555555"
  @monitor_agent_user_id "66666666-6666-6666-6666-666666666666"
  @coder_agent_user_id "77777777-7777-7777-7777-777777777777"
  @researcher_agent_user_id "88888888-8888-8888-8888-888888888888"
  @marketing_agent_user_id "99999999-9999-9999-9999-999999999999"
  @social_agent_user_id "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  @media_agent_user_id "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
  @claude_avatar_data_url "https://media.vibegram.io/chat-media/agent-profiles/claude.png"
  @codex_avatar_data_url "https://media.vibegram.io/chat-media/agent-profiles/codex.png"
  @grok_avatar_data_url "https://media.vibegram.io/chat-media/agent-profiles/grok-v2.png"
  @agy_avatar_data_url "https://media.vibegram.io/chat-media/agent-profiles/agy-v3.png"
  @default_timeout_ms 120_000
  @default_team_timeout_ms 600_000
  @max_prompt_length 8_000
  @max_tool_events 16
  @max_activity_summary_items 6
  @max_payload_preview_bytes 1_200
  @max_runtime_files 32
  @max_runtime_patch_bytes 90_000
  @rate_limit_table :local_agent_worker_ratelimit
  @session_table :local_agent_worker_sessions
  @team_run_table :local_agent_worker_team_runs
  # Suppress double-posts when two bridges both finish the same logical turn.
  @deliver_dedupe_table :local_agent_worker_deliver_dedupe
  @deliver_dedupe_ttl_ms 90_000
  @default_cooldown_ms 8_000
  # Hop cap for agent-to-agent handoff; a chain cannot outlive this many relays.
  @team_relay_max_hops 4

  # Role workers answer in a group chat, not a terminal: short, and no side quests.
  @team_chat_rules """
  You are answering inside a Vibe group chat, not a terminal session. Give the answer
  itself in under 150 words — no headings, no plan file, no report template. Do not
  spawn subagents and do not start a background investigation; if the work needs more
  than a couple of minutes, say what you would do and stop there. To hand work to a
  teammate, @mention exactly one of them on the last line.
  """
  @worker_order ["claude", "codex", "grok", "agy", "boss", "monitor", "coder", "researcher", "marketing", "social", "media"]
  @role_worker_order ["boss", "monitor", "coder", "researcher", "marketing", "social", "media"]

  # "@coder" or "@coder [max]" — the bracketed level, when present, is the pinned effort.
  @mention_pattern ~r/(?:^|\s)@(codex|claude|grok|agy|antigravity|boss|monitor|coder|researcher|marketing|social|media)\b(?:\s*[\[(]\s*(low|medium|high|xhigh|extra[-_ ]?high|max|ultrathink)\s*[\])])?/i

  @workers %{
    "codex" => %{
      handle: "codex",
      label: "Codex",
      command_env: "VIBE_CODEX_COMMAND",
      default_command: "codex",
      agent_user_id: @codex_agent_user_id,
      username: "codex",
      name: "Codex",
      avatar_url: @codex_avatar_data_url,
      tier: "gold"
    },
    "claude" => %{
      handle: "claude",
      label: "Claude",
      command_env: "VIBE_CLAUDE_COMMAND",
      default_command: "claude",
      agent_user_id: @claude_agent_user_id,
      username: "claude",
      name: "Claude",
      avatar_url: @claude_avatar_data_url,
      tier: "gold"
    },
    "grok" => %{
      handle: "grok",
      label: "Grok",
      command_env: "VIBE_GROK_COMMAND",
      default_command: "grok",
      agent_user_id: @grok_agent_user_id,
      username: "grok",
      name: "Grok",
      avatar_url: @grok_avatar_data_url,
      tier: "gold"
    },
    "agy" => %{
      handle: "agy",
      label: "Agy",
      command_env: "VIBE_AGY_COMMAND",
      default_command: "agy",
      agent_user_id: @agy_agent_user_id,
      username: "agy",
      name: "Agy",
      avatar_url: @agy_avatar_data_url,
      tier: "gold"
    },
    "boss" => %{
      handle: "boss",
      label: "Boss",
      executor: "claude",
      runtime: :server,
      model: "fable",
      fallback_model: "opus",
      effort: "max",
      command_env: "VIBE_CLAUDE_COMMAND",
      default_command: "claude",
      agent_user_id: @boss_agent_user_id,
      username: "boss",
      name: "Boss",
      avatar_url: nil,
      tier: "gold",
      role_prompt: """
      You are the Boss (chief of staff) for the Vibe team. You do not do the work
      yourself: you decide who does, then hand it over by @mentioning exactly one
      teammate in this chat and stating the outcome you expect. Your team is
      @monitor and @coder for DevOps, then @researcher, @marketing, @social, @media.
      You set how hard a teammate thinks: write the level in brackets after the
      handle — @coder [max] for a deep job, @social [low] for a quick one. Levels
      are low, medium, high, xhigh, max; leave it off to use their default.
      Keep your own replies to a few lines. If a request is already assigned, say
      so and stay quiet.
      """
    },
    "monitor" => %{
      handle: "monitor",
      label: "Monitor",
      executor: "claude",
      runtime: :server,
      model: "haiku",
      effort: "low",
      command_env: "VIBE_CLAUDE_COMMAND",
      default_command: "claude",
      agent_user_id: @monitor_agent_user_id,
      username: "monitor",
      name: "Monitor",
      avatar_url: nil,
      tier: "gold",
      role_prompt: """
      You are Monitor, the watch half of the DevOps team. You own security status,
      logging, health and incident triage, for the SERVER and for the iOS client.
      Read production logs with deploy/scripts/vibe-logs.sh (never SSH to read;
      see docs/vps-logs.md). Client crashes arrive as client log reports.
      You investigate and report; you do NOT patch or deploy. When something needs
      a code change, hand it to @coder in one message: what broke, the evidence
      (log lines, file:line), and how to reproduce. Be terse. If nothing is wrong,
      say so in one line.
      """
    },
    "coder" => %{
      handle: "coder",
      label: "Coder",
      executor: "claude",
      runtime: :server,
      model: "opus",
      effort: "xhigh",
      command_env: "VIBE_CLAUDE_COMMAND",
      default_command: "claude",
      agent_user_id: @coder_agent_user_id,
      username: "coder",
      name: "Coder",
      avatar_url: nil,
      tier: "gold",
      role_prompt: """
      You are Coder, the build half of the DevOps team. You own patching, code
      review, updating, launching and deploying. @monitor hands you incidents; you
      diagnose, write the fix, review it, and take it to a deploy.
      Deploying is gated: follow docs/deploy-pipeline.md and never push or deploy
      without saying what you are about to do first. If a fix is not obvious,
      say what you would need instead of guessing. Report back to @monitor when
      the fix is in so it can confirm the signal cleared.
      """
    },
    "researcher" => %{
      handle: "researcher",
      label: "Researcher",
      executor: "codex",
      runtime: :server,
      model: nil,
      effort: "high",
      command_env: "VIBE_CODEX_COMMAND",
      default_command: "codex",
      agent_user_id: @researcher_agent_user_id,
      username: "researcher",
      name: "Researcher",
      avatar_url: nil,
      tier: "gold",
      role_prompt: """
      You are Researcher for the Vibe team. You answer questions with sources, not
      impressions. Every claim you hand back carries a link or a file:line. When
      you are asked something you cannot verify, say which part is unverified.
      Hand findings to whoever asked; do not start work of your own.
      """
    },
    "marketing" => %{
      handle: "marketing",
      label: "Marketing",
      executor: "claude",
      runtime: :server,
      model: "sonnet",
      effort: "medium",
      command_env: "VIBE_CLAUDE_COMMAND",
      default_command: "claude",
      agent_user_id: @marketing_agent_user_id,
      username: "marketing",
      name: "Marketing",
      avatar_url: nil,
      tier: "gold",
      role_prompt: """
      You are Marketing for Vibe. You own positioning, launch copy and the story
      of what shipped. Ask @coder or @monitor what actually changed before you
      write about it — never describe a feature you have not confirmed exists.
      Hand finished copy to @social to post.
      """
    },
    "social" => %{
      handle: "social",
      label: "Social",
      executor: "claude",
      runtime: :server,
      model: "haiku",
      effort: "low",
      command_env: "VIBE_CLAUDE_COMMAND",
      default_command: "claude",
      agent_user_id: @social_agent_user_id,
      username: "social",
      name: "Social",
      avatar_url: nil,
      tier: "gold",
      role_prompt: """
      You are the Social Manager for Vibe. You own the accounts and the posting
      calendar. You write short, you post on approval, and you never publish
      anything naming a customer without it. Ask @marketing for the angle and
      @media for the asset.
      """
    },
    "media" => %{
      handle: "media",
      label: "Media",
      executor: "claude",
      runtime: :server,
      model: "sonnet",
      effort: "medium",
      command_env: "VIBE_CLAUDE_COMMAND",
      default_command: "claude",
      agent_user_id: @media_agent_user_id,
      username: "media",
      name: "Media",
      avatar_url: nil,
      tier: "gold",
      role_prompt: """
      You are Media for Vibe. You brief and assemble visual assets — screenshots,
      captures, cuts — for whatever @social and @marketing are shipping. You
      specify the asset precisely (size, frame, what is on screen) and say where
      it lives. If you cannot produce it, say what you need.
      """
    }
  }

  def agent_user_id, do: @agent_user_id

  @doc "All worker definitions keyed by handle."
  def workers, do: @workers

  @doc "List of all worker definitions."
  def list_workers do
    @worker_order
    |> Enum.map(&Map.fetch!(@workers, &1))
  end

  @doc "Role workers only — the job-named team (boss, monitor, coder, ...)."
  def list_role_workers do
    Enum.map(@role_worker_order, &Map.fetch!(@workers, &1))
  end

  @doc "Which CLI actually runs this worker. Role workers borrow claude/codex."
  def executor_for(worker) do
    team_executor_override(worker) || declared_executor(worker)
  end

  defp declared_executor(%{executor: executor}) when is_binary(executor), do: executor
  defp declared_executor(%{handle: handle}), do: handle

  # One signed-in CLI can stand in for the whole team when the others have no seat.
  defp team_executor_override(worker) do
    if server_runtime?(worker) do
      System.get_env("VIBE_TEAM_EXECUTOR")
      |> normalize_string()
      |> case do
        value when value in ["claude", "codex", "grok"] -> value
        _ -> nil
      end
    end
  end

  @doc "Role workers run their CLI on the server; the four provider workers need a paired bridge."
  def server_runtime?(worker), do: Map.get(worker, :runtime) == :server

  # Output is CLI-shaped, so a role worker's reply must be parsed as its executor's.
  defp parser_worker(%{handle: handle} = worker) do
    case executor_for(worker) do
      ^handle -> worker
      executor -> %{worker | handle: executor}
    end
  end

  # A role worker carries its own model so cost tracks the job, not a global env.
  defp put_worker_model(worker, opts) do
    metadata = Keyword.get(opts, :bridge_metadata) || %{}

    metadata =
      if executor_for(worker) == declared_executor(worker) do
        metadata
        |> put_worker_option("model", Map.get(worker, :model))
        |> put_worker_option("fallbackModel", Map.get(worker, :fallback_model))
        |> put_worker_option("reasoningEffort", Map.get(worker, :effort))
      else
        metadata
      end

    Keyword.put(opts, :bridge_metadata, pin_worker_effort(metadata, worker))
  end

  # A level named on the mention outranks both the roster default and the app pick.
  defp pin_worker_effort(metadata, worker) do
    case normalize_string(Map.get(worker, :effort_directive)) do
      nil -> metadata
      level -> Map.put(metadata, "reasoningEffort", level)
    end
  end

  # A roster default never overrides what the caller asked for.
  defp put_worker_option(metadata, key, value) do
    with true <- is_binary(value) and value != "",
         nil <- normalize_string(option_value(metadata, key)) do
      Map.put(metadata, key, value)
    else
      _ -> metadata
    end
  end

  @doc "The dedicated agent user id for a worker (claude/codex are distinct users)."
  def worker_agent_user_id(%{agent_user_id: id}), do: id

  @doc "Resolve a worker by its dedicated shadow-user id (e.g. for DM auto-routing)."
  def resolve_by_agent_user_id(user_id) when is_binary(user_id) do
    normalized = user_id |> String.trim() |> String.downcase()

    Enum.find_value(@workers, fn {_handle, worker} ->
      if String.downcase(worker.agent_user_id) == normalized, do: worker
    end)
  end

  def resolve_by_agent_user_id(_), do: nil

  @doc """
  Upsert the Claude/Codex agent user records so they are searchable users you can
  DM. Idempotent — safe to call on every boot.
  """
  def ensure_agent_users do
    Enum.each(list_workers(), &ensure_agent_user_record/1)
  end

  def resolve_handle(value) when is_binary(value) do
    value
    |> normalize_handle()
    |> case do
      handle when is_map_key(@workers, handle) -> Map.fetch!(@workers, handle)
      _ -> nil
    end
  end

  def resolve_handle(_), do: nil

  def resolve_from_message(%{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("agentWorkerProvider")
    |> resolve_handle()
  end

  def resolve_from_message(_), do: nil

  def extract_reserved_mention(text) when is_binary(text) do
    case Regex.run(@mention_pattern, text) do
      [_ | captures] -> mention_worker(captures)
      _ -> nil
    end
  end

  def extract_reserved_mention(_), do: nil

  def extract_reserved_mentions(text) when is_binary(text) do
    @mention_pattern
    |> Regex.scan(text)
    |> Enum.map(fn
      [_ | captures] -> mention_worker(captures)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.handle)
  end

  def extract_reserved_mentions(_), do: []

  defp mention_worker([handle | rest]) do
    h = String.downcase(handle)

    case resolve_handle(if(h == "antigravity", do: "agy", else: h)) do
      nil -> nil
      worker -> pin_mention_effort(worker, List.first(rest))
    end
  end

  defp mention_worker(_), do: nil

  # A mention may name the thinking level — "@coder [max]" — and that beats the roster.
  defp pin_mention_effort(worker, level) do
    case normalize_string(level) do
      nil -> worker
      value -> Map.put(worker, :effort_directive, String.downcase(value))
    end
  end

  @doc """
  Whether a message is a short greeting / acknowledgement / chit-chat with no actionable task.
  """
  def casual_message?(text) when is_binary(text) do
    normalized = text |> String.downcase() |> String.trim()

    cond do
      normalized == "" ->
        true

      String.length(normalized) <= 40 and
          Regex.match?(
            ~r/^(hi+|hey+|hello+|yo|gm|gn|good (morning|afternoon|evening|night)|sup|what'?s up|howdy|hiya|hola|greetings|thanks|thank you|ty|thx|cheers|ok|okay|k|cool|nice|great|awesome|got it|gotcha|lol+|haha+|hehe|👋|🙏|👍|🙂|😄)[\s!.,?👋🙏👍🙂😄]*$/u,
            normalized
          ) ->
        true

      true ->
        false
    end
  end

  def casual_message?(_), do: false

  @doc "Whether a message is explicitly asking the local AI workers to run as a team."
  def team_trigger?(text) when is_binary(text) do
    Regex.match?(~r/(?:^|\s)(?:@team|\/team)\b/i, text) or
      Regex.match?(~r/^\s*team\s*:/i, text)
  end

  def team_trigger?(_), do: false

  @doc "Remove the team command token before sending the actual user task to providers."
  def strip_team_trigger(text) when is_binary(text) do
    text
    |> String.replace(~r/(^|\s)(?:@team|\/team)\b/i, "\\1")
    |> String.replace(~r/^\s*team\s*:\s*/i, "")
    |> String.trim()
    |> case do
      "" -> String.trim(text)
      cleaned -> cleaned
    end
  end

  def strip_team_trigger(text), do: text

  @doc """
  Return local workers whose shadow users are participants in the group.
  """
  def team_workers_for_participants(participant_ids) when is_list(participant_ids) do
    normalized_ids =
      participant_ids
      |> Enum.map(&(to_string(&1) |> String.downcase() |> String.trim()))
      |> MapSet.new()

    list_workers()
    |> Enum.filter(fn worker ->
      MapSet.member?(normalized_ids, String.downcase(worker.agent_user_id))
    end)
  end

  def team_workers_for_participants(_), do: []

  def enabled? do
    truthy?(System.get_env("VIBE_LOCAL_AGENT_WORKERS"))
  end

  @doc """
  Per-user cooldown gate.
  """
  def allow_request?(user_id) when is_binary(user_id) and user_id != "" do
    ensure_rate_limit_table()
    now = System.monotonic_time(:millisecond)
    cooldown = cooldown_ms()

    case :ets.lookup(@rate_limit_table, user_id) do
      [{^user_id, last}] when now - last < cooldown ->
        false

      _ ->
        :ets.insert(@rate_limit_table, {user_id, now})
        true
    end
  end

  def allow_request?(_), do: true

  @doc """
  Post a short non-result notice into the chat (rate-limited / busy messages),
  attributed to the worker agent.
  """
  def post_notice(worker, chat_id, text, requester_user_id, reply_to_id) when is_map(worker) do
    post_worker_message(
      worker,
      chat_id,
      text,
      %{
        "agentWorker" => true,
        "agentWorkerProvider" => worker.handle,
        "agentWorkerOk" => false,
        "agentWorkerNotice" => true
      },
      reply_to_id,
      requester_user_id
    )
  end

  defp ensure_rate_limit_table do
    case :ets.whereis(@rate_limit_table) do
      :undefined ->
        :ets.new(@rate_limit_table, [:set, :public, :named_table, {:read_concurrency, true}])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp cooldown_ms do
    case Integer.parse(System.get_env("VIBE_AGENT_WORKER_COOLDOWN_MS") || "") do
      {value, _} when value >= 0 -> value
      _ -> @default_cooldown_ms
    end
  end

  @doc """
  Authorization gate.
  """
  def user_allowed?(user_id) do
    case allowed_users() do
      [] -> true
      list -> is_binary(user_id) and user_id in list
    end
  end

  @doc """
  Role workers run a CLI on our own server, so they fail CLOSED: an empty
  allowlist means nobody, not everybody. Bridge workers keep the old gate.
  """
  def dispatch_allowed?(worker, user_id) do
    if server_runtime?(worker) do
      is_binary(user_id) and user_id in allowed_users()
    else
      user_allowed?(user_id)
    end
  end

  defp allowed_users do
    case normalize_string(System.get_env("VIBE_AGENT_WORKER_ALLOWED_USERS")) do
      nil ->
        []

      raw ->
        raw
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp ensure_session_table do
    case :ets.whereis(@session_table) do
      :undefined ->
        :ets.new(@session_table, [:set, :public, :named_table, {:read_concurrency, true}])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp store_session(nil, _handle, _session_id), do: :ok
  defp store_session(_chat_id, _handle, nil), do: :ok

  defp store_session(chat_id, handle, session_id) do
    ensure_session_table()
    :ets.insert(@session_table, {{chat_id, handle}, session_id})
    :ok
  end

  defp session_id_from_output(output) do
    output
    |> decoded_events()
    |> Enum.find_value(fn event -> normalize_string(event["session_id"]) end)
  end

  def handle_chat_message(worker, chat_id, prompt, opts \\ []) when is_map(worker) do
    reply_to_id = Keyword.get(opts, :reply_to_id)
    requester_user_id = Keyword.get(opts, :requester_user_id)
    progress_callback = Keyword.get(opts, :progress_callback, fn _event -> :ok end)

    with {:ok, normalized_prompt} <- normalize_prompt(worker, prompt),
         {:ok, result} <-
           run(worker, normalized_prompt,
             progress_callback: progress_callback,
             chat_id: chat_id,
             bridge_metadata: Keyword.get(opts, :bridge_metadata)
           ) do
      visible = visible_response_text(result.text, result.tool_events)
      relay_to_teammates(worker, chat_id, visible, requester_user_id, Keyword.get(opts, :hop, 0))

      post_worker_message(
        worker,
        chat_id,
        visible,
        %{
          "agentWorker" => true,
          "agentWorkerProvider" => worker.handle,
          "agentWorkerCommand" => result.command,
          "agentWorkerExitStatus" => result.exit_status,
          "agentWorkerDurationMs" => result.duration_ms,
          "agentWorkerOk" => result.ok,
          "agentWorkerToolEvents" => result.tool_events,
          "agentWorkerAvailableTools" => result.available_tools,
          "agentWorkerRawEventCount" => result.raw_event_count,
          "progressNodes" => result.progress_nodes
        },
        reply_to_id,
        requester_user_id
      )
    else
      {:error, reason} ->
        post_worker_message(
          worker,
          chat_id,
          error_message(worker, reason),
          %{
            "agentWorker" => true,
            "agentWorkerProvider" => worker.handle,
            "agentWorkerOk" => false,
            "agentWorkerError" => inspect(reason)
          },
          reply_to_id,
          requester_user_id
        )
    end
  end

  # Agents hand work over by @mentioning ONE teammate. Bounded to a single target
  # per reply plus a hop cap, so a mutual mention can neither fan out nor loop.
  defp relay_to_teammates(worker, chat_id, text, requester_user_id, hop) do
    with true <- hop < @team_relay_max_hops,
         true <- server_runtime?(worker),
         %{} = target <- first_teammate_mention(text, worker) do
      Task.Supervisor.start_child(Vibe.AI.WorkerTaskSupervisor, fn ->
        handle_chat_message(target, chat_id, text,
          requester_user_id: requester_user_id,
          hop: hop + 1
        )
      end)
    end

    :ok
  end

  defp first_teammate_mention(text, worker) do
    self_handle = Map.get(worker, :handle)

    ~r/(?:^|\s)@([a-zA-Z_]{2,20})\b/
    |> Regex.scan(to_string(text))
    |> Enum.find_value(fn [_, handle] ->
      h = String.downcase(handle)

      with true <- h != self_handle,
           %{} = target <- resolve_handle(h),
           true <- server_runtime?(target) do
        target
      else
        _ -> nil
      end
    end)
  end

  def run(worker, prompt, opts \\ []) when is_map(worker) and is_binary(prompt) do
    cond do
      not enabled?() ->
        {:error, :local_agent_workers_disabled}

      String.length(prompt) > @max_prompt_length ->
        {:error, :prompt_too_long}

      true ->
        command = command_for(worker)

        case System.find_executable(command) do
          nil ->
            {:error, {:command_not_found, command}}

          executable ->
            do_run(worker, executable, prompt, opts)
        end
    end
  end

  def parse_result(provider, output) when is_binary(provider) and is_binary(output) do
    case resolve_handle(provider) do
      nil -> {:error, :unknown_provider}
      worker -> {:ok, extract_result(worker, output)}
    end
  end


  @doc """
  Turn a single raw stream-json line from a bridge daemon into a progress event (or nil if the
  line carries no tool activity).
  """
  def bridge_progress_event(provider, line) when is_binary(line) do
    case resolve_handle(provider) do
      nil -> nil
      worker -> progress_event_from_line(line, worker)
    end
  end

  def bridge_progress_event(_provider, _line), do: nil

  @doc """
  Parse a completed bridge run (raw output + exit status) and post the result as the agent's
  message into the chat.
  """
  def deliver_bridge_result(provider, chat_id, output, exit_status, duration_ms, opts \\ [])
      when is_binary(provider) and is_binary(chat_id) and is_binary(output) do
    case resolve_handle(provider) do
      nil ->
        {:error, :unknown_provider}

      worker ->
        reply_to_id = Keyword.get(opts, :reply_to_id)
        requester_user_id = Keyword.get(opts, :requester_user_id)

        runtime =
          Keyword.get(opts, :runtime)
          |> normalize_runtime_payload()
          |> merge_team_runtime(opts)

        runtime_enc = normalize_runtime_enc(Keyword.get(opts, :runtime_enc))
        agent_actions_enc = normalize_runtime_enc(Keyword.get(opts, :agent_actions_enc))
        runtime_can_revert = Keyword.get(opts, :can_revert) == true
        team_metadata = normalize_team_metadata(opts)
        extracted = extract_result(worker, output)
        progress_nodes = progress_nodes_with_runtime(extracted.progress_nodes, runtime)
        ok = exit_status == 0
        base_text = extracted.text || fallback_output(output)

        body =
          if ok do
            visible_response_text(base_text, extracted.tool_events)
          else
            visible_response_text(
              command_failed_text(worker, exit_status, base_text),
              extracted.tool_events
            )
          end

        usage_limit_hit? =
          Keyword.get(opts, :usage_limit_hit) == true or
            usage_limit_text?(base_text) or
            usage_limit_text?(body) or
            usage_limit_runtime?(runtime)

        suppress_visible? =
          Keyword.get(opts, :suppress_visible) == true or
            Keyword.get(opts, :suppressVisible) == true or
            truthy_opt?(Keyword.get(opts, :suppress_visible)) or
            truthy_opt?(team_metadata["suppressVisible"]) or
            truthy_opt?(team_metadata["agentWorkerSuppressVisible"])

        team_run_id = normalize_string(Keyword.get(opts, :team_run_id))
        team_mode = normalize_string(Keyword.get(opts, :team_mode))

        if ok or is_binary(team_run_id) do
          note_bridge_agent_turn(chat_id, worker, base_text, requester_user_id,
            team_run_id: team_run_id,
            task_id: normalize_string(Keyword.get(opts, :task_id)),
            team_role: normalize_string(Keyword.get(opts, :team_role)),
            status: if(ok, do: "done", else: "failed")
          )
        end

        worker_status_list =
          if is_binary(team_run_id) do
            settle_task_id = normalize_string(Keyword.get(opts, :task_id))

            stored_entry =
              case fetch_supervisor_run_state(chat_id, team_run_id) do
                state when is_map(state) ->
                  get_in(state, [:worker_states, worker.handle]) || %{}

                _ ->
                  %{}
              end

            stored_task_id = normalize_string(stored_entry["task_id"])
            stored_status = normalize_string(stored_entry["status"])

            stale_attempt? =
              is_binary(settle_task_id) and is_binary(stored_task_id) and
                settle_task_id != stored_task_id

            already_closed? = stored_status in ["cancelled", "reassigned"]

            if stale_attempt? or already_closed? do
              Logger.info(
                "[LocalAgentWorker] stale settle ignored chat=#{chat_id} run=#{team_run_id} " <>
                  "worker=#{worker.handle} settled=#{settle_task_id} current=#{stored_task_id} " <>
                  "status=#{inspect(stored_status)}"
              )

              team_workers_status(chat_id, team_run_id)
            else
              list =
                update_team_worker_state(chat_id, team_run_id, worker.handle, %{
                  "status" => if(ok, do: "done", else: "failed"),
                  "summary" => String.slice(base_text || "", 0, 400),
                  "last_label" => if(ok, do: "done", else: "failed"),
                  "task_id" => Keyword.get(opts, :task_id)
                })

              Vibe.AI.TeamRunMonitor.note_settled(
                chat_id,
                team_run_id,
                worker.handle,
                ok,
                usage_limit_hit?,
                not signal_exit_status?(exit_status)
              )

              list
            end
          else
            []
          end

        Logger.info(
          "[AgentBridge] deliver chat=#{chat_id} provider=#{worker.handle} ok=#{ok} usageLimit=#{usage_limit_hit?} suppressVisible=#{suppress_visible?} rawEvents=#{extracted.raw_event_count} baseTextLen=#{String.length(base_text || "")} bodyLen=#{String.length(body || "")}"
        )

        metadata =
          %{
            "agentWorker" => true,
            "agentWorkerProvider" => worker.handle,
            "agentWorkerVia" => "bridge",
            "agentWorkerExitStatus" => exit_status,
            "agentWorkerDurationMs" => duration_ms,
            "agentWorkerOk" => ok,
            "agentWorkerToolEvents" => extracted.tool_events,
            "agentWorkerAvailableTools" => extracted.available_tools,
            "agentWorkerRawEventCount" => extracted.raw_event_count,
            "progressNodes" => progress_nodes
          }
          |> maybe_put("agentRuntime", runtime)
          |> maybe_put("agentRuntimeEnc", runtime_enc)
          |> maybe_put("agentActionsEnc", agent_actions_enc)
          |> maybe_put("agentRuntimeCanRevert", if(runtime_can_revert, do: true))
          |> maybe_put("suppressVisible", if(suppress_visible?, do: true))
          |> maybe_put("teamWorkersStatus", worker_status_list)
          |> then(fn meta ->
            if usage_limit_hit? do
              meta
              |> Map.put("agentWorkerUsageLimit", true)
              |> Map.put("agentWorkerNotice", true)
            else
              meta
            end
          end)
          |> Map.merge(team_metadata)

        result =
          cond do
            usage_limit_hit? and not ok ->
              Logger.info(
                "[AgentBridge] suppress usage-limit row chat=#{chat_id} provider=#{worker.handle}"
              )

              VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-usage-limit", %{
                "provider" => worker.handle,
                "chatId" => chat_id,
                "message" => base_text || body,
                "replyToId" => reply_to_id
              })

              {:ok, %{message_id: nil, suppressed: true, usage_limit: true}}

            suppress_visible? ->
              Logger.info(
                "[AgentBridge] suppress under-hood worker row chat=#{chat_id} provider=#{worker.handle} run=#{inspect(team_run_id)}"
              )

              broadcast_team_worker_settled(
                chat_id,
                worker,
                team_run_id,
                team_mode,
                worker_status_list,
                ok,
                base_text
              )

              {:ok, %{message_id: nil, suppressed: true, under_hood: true}}

            duplicate_bridge_delivery?(chat_id, worker.handle, reply_to_id, body) ->
              Logger.info(
                "[AgentBridge] suppress duplicate deliver chat=#{chat_id} provider=#{worker.handle} reply_to=#{inspect(reply_to_id)}"
              )

              {:ok, %{message_id: nil, suppressed: true, duplicate: true}}

            true ->
              post_worker_message(
                worker,
                chat_id,
                body,
                metadata,
                reply_to_id,
                requester_user_id
              )
          end

        case result do
          {:ok, %{suppressed: true, usage_limit: true}} ->
            Logger.info(
              "[AgentBridge] deliver suppressed usage-limit chat=#{chat_id} provider=#{worker.handle}"
            )

          {:ok, %{suppressed: true, under_hood: true}} ->
            Logger.info(
              "[AgentBridge] deliver suppressed under-hood chat=#{chat_id} provider=#{worker.handle}"
            )

          {:ok, %{message_id: mid}} ->
            Logger.info("[AgentBridge] deliver posted chat=#{chat_id} message_id=#{inspect(mid)}")

          other ->
            Logger.error(
              "[AgentBridge] deliver FAILED chat=#{chat_id} provider=#{worker.handle} reason=#{inspect(other)}"
            )
        end

        if ok do
          maybe_dispatch_next_team_worker(chat_id, worker, requester_user_id, opts)
        else
          unless usage_limit_hit? or suppress_visible? do
            fail_bridge_team_run(
              chat_id,
              team_run_id,
              worker.handle,
              "@#{worker.handle} exited with status #{exit_status}: #{base_text}"
            )
          end
        end

        result
    end
  end

  defp truthy_opt?(true), do: true
  defp truthy_opt?("true"), do: true
  defp truthy_opt?("1"), do: true
  defp truthy_opt?(1), do: true
  defp truthy_opt?(_), do: false

  defp signal_exit_status?(status) when status in [130, 137, 143], do: true

  defp signal_exit_status?(status) when is_binary(status) do
    case Integer.parse(status) do
      {value, _} -> signal_exit_status?(value)
      _ -> false
    end
  end

  defp signal_exit_status?(_), do: false

  defp broadcast_team_worker_settled(
         chat_id,
         worker,
         team_run_id,
         team_mode,
         worker_status_list,
         ok,
         summary
       )
       when is_binary(chat_id) and is_binary(team_run_id) do
    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-team-worker", %{
      "chatId" => chat_id,
      "teamRunId" => team_run_id,
      "teamMode" => team_mode || "supervisor",
      "teamWorker" => worker.handle,
      "agentUserId" => worker.agent_user_id,
      "agentName" => worker.label,
      "status" => if(ok, do: "done", else: "failed"),
      "summary" => String.slice(summary || "", 0, 400),
      "teamWorkersStatus" => worker_status_list,
      "suppressVisible" => true
    })

    :ok
  end

  defp broadcast_team_worker_settled(_, _, _, _, _, _, _), do: :ok

  defp usage_limit_text?(text) when is_binary(text) do
    t = String.downcase(text)

    String.contains?(t, "usage limit") or
      String.contains?(t, "session limit") or
      String.contains?(t, "rate limit") or
      String.contains?(t, "you've hit your") or
      String.contains?(t, "youve hit your") or
      String.contains?(t, "hit your usage") or
      String.contains?(t, "hit your session") or
      String.contains?(t, "quota exceeded") or
      String.contains?(t, "quota exhausted") or
      String.contains?(t, "out of usage") or
      String.contains?(t, "out of credits") or
      Regex.match?(~r/reached your .{0,40}limit/, t)
  end

  defp usage_limit_text?(_), do: false

  defp usage_limit_runtime?(runtime) when is_map(runtime) do
    runtime["usageLimitHit"] == true or runtime["usage_limit_hit"] == true or
      usage_limit_text?(runtime["usageLimitMessage"] || runtime["usage_limit_message"] || "")
  end

  defp usage_limit_runtime?(_), do: false

  @doc "Post a short notice (e.g. errors from the bridge) attributed to a worker."
  def post_bridge_notice(provider, chat_id, text, requester_user_id, reply_to_id) do
    case resolve_handle(provider) do
      nil ->
        {:error, :unknown_provider}

      worker ->
        if usage_limit_text?(text) do
          VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-usage-limit", %{
            "provider" => worker.handle,
            "chatId" => chat_id,
            "message" => text,
            "replyToId" => reply_to_id
          })

          {:ok, %{suppressed: true, usage_limit: true}}
        else
          post_notice(worker, chat_id, text, requester_user_id, reply_to_id)
        end
    end
  end


  @doc """
  Build the prompt to send to the bridge.
  """
  def build_bridge_prompt(chat_id, worker, dispatch_text, requester_user_id, opts \\ [])

  def build_bridge_prompt(chat_id, worker, dispatch_text, requester_user_id, opts)
      when is_binary(chat_id) and is_map(worker) and is_binary(dispatch_text) and is_list(opts) do
    if group_chat?(chat_id) do
      context = group_collaboration_context(chat_id, requester_user_id)
      repo_line = selected_repo_prompt_line(opts)

      if casual_message?(dispatch_text) do
        """
        #{group_framing(worker)}
        #{repo_line}

        The latest message is casual conversation, not a work request. Reply briefly and in a friendly, human way. Do NOT read repo files (AGENTS.md, CLAUDE.md, etc.), inspect the codebase, or run any tools — only start doing real work once the user actually asks for it.

        Shared conversation so far:
        #{context_or_empty(context)}

        Latest message for you (#{worker.label}):
        #{dispatch_text}
        """
        |> String.trim()
      else
        """
        #{group_framing(worker)}
        #{repo_line}

        #{agent_operating_rules(worker)}
        #{platform_connectors_guidance(requester_user_id, worker)}

        Shared conversation so far (you can see everyone's recent messages and the other agents' work; build on it and do not repeat completed work):
        #{context_or_empty(context)}

        Latest request for you (#{worker.label}):
        #{dispatch_text}
        """
        |> String.trim()
      end
    else
      with_platform =
        case platform_connectors_guidance(requester_user_id, worker) do
          nil -> dispatch_text
          guidance -> guidance <> "\n\n" <> dispatch_text
        end

      with_platform
    end
  end

  def build_bridge_prompt(_chat_id, _worker, dispatch_text, _requester, _opts), do: dispatch_text

  defp selected_repo_prompt_line(opts) when is_list(opts) do
    meta = Keyword.get(opts, :bridge_metadata) || %{}

    cwd =
      normalize_string(meta["cwd"] || meta[:cwd] || meta["agentBridgeCwd"])

    name =
      normalize_string(
        meta["repoName"] || meta[:repoName] || meta["agentBridgeRepoName"] || meta["repo_name"]
      )

    path =
      normalize_string(
        meta["repoPath"] || meta[:repoPath] || meta["agentBridgeRepoPath"] || meta["repo_path"]
      )

    location = cwd || path

    cond do
      is_binary(location) and location != "" and is_binary(name) and name != "" ->
        "Selected working directory: #{name} at #{location}. You may mention it if useful. Do NOT open or edit files until the user requests real work."

      is_binary(location) and location != "" ->
        "Selected working directory: #{location}. You may mention it if useful. Do NOT open or edit files until the user requests real work."

      true ->
        "No working directory was selected on the phone for this turn — if the user asks about a repo, ask them which path to use."
    end
  end

  defp selected_repo_prompt_line(_), do: ""

  @doc """
  Pick the responsible lead for a supervisor team run.
  """
  def pick_supervisor_lead(workers) when is_list(workers) do
    preferred = ["claude", "codex", "grok", "agy"]

    Enum.find_value(preferred, fn handle ->
      Enum.find(workers, &(&1.handle == handle))
    end) || List.first(workers)
  end

  def pick_supervisor_lead(_), do: nil

  @doc """
  Cheap, repo-agnostic gate on a `@team` request, run BEFORE any provider turn.
  """
  @spec classify_team_request(any()) :: :chat | :complex
  def classify_team_request(text) when is_binary(text) do
    t = text |> String.trim() |> String.downcase()

    cond do
      conversational_request?(t) -> :chat
      not work_request?(t) -> :chat
      true -> :complex
    end
  end

  def classify_team_request(_), do: :chat

  defp conversational_request?(t) when is_binary(t) do
    Regex.match?(
      ~r/^\s*(can|could|are|is|do|does|did|will|would|should)\s+(you|it|we|this|that|there)\b[^.!?]*\b(see|read|view|open|access|tell|know|think|understand|explain|describe|remember|handle|support)\b|^\s*(what|why|how come|who|which|when|where|explain|describe|tell me|show me|thoughts|any thoughts|wdyt|opinion)\b|^\s*(hi|hey|hello|yo|thanks|thank you|ok|okay|nice|cool|got it)\b\s*[.!?]*\s*$/,
      t
    )
  end

  defp conversational_request?(_), do: false

  defp work_request?(t) when is_binary(t) do
    Regex.match?(
      ~r/\b(build|create|make|add|implement|write|code|fix|patch|change|update|edit|modify|adjust|refactor|rename|move|remove|delete|drop|revert|install|upgrade|migrate|deploy|ship|release|publish|configure|configure|set ?up|setup|wire|integrate|connect|optimi[sz]e|clean ?up|scaffold|generate|port|convert|replace|improve|redesign|restyle|polish|finish|complete|continue|run|test|lint|format|debug|solve|handle|support)\b/,
      t
    )
  end

  defp work_request?(_), do: false

  @doc """
  Did the user EXPLICITLY address the whole team ("call all agents", "what do you all think",
  "everyone introduce yourselves")?
  """
  @spec all_agents_request?(any()) :: boolean()
  def all_agents_request?(text) when is_binary(text) do
    t = text |> String.trim() |> String.downcase()

    Regex.match?(
      ~r/\b(all( of the| the)? agents|every agent|each agent|all of you|each of you|you all|y'all|all together|everyone|everybody|whole team|entire team|full team|all (team )?members|all four of you|all 4 of you)\b/,
      t
    )
  end

  def all_agents_request?(_), do: false

  @doc """
  Pick the single best-provider worker to handle a SIMPLE `@team` request visibly — its live
  frames ARE the progress the user sees.
  """
  def pick_solo_worker(workers, text) when is_list(workers) and is_binary(text) do
    preference =
      if ui_flavored_request?(text) do
        ["grok", "claude", "codex", "agy"]
      else
        ["codex", "claude", "grok", "agy"]
      end

    Enum.find_value(preference, fn handle ->
      Enum.find(workers, &(&1.handle == handle))
    end) || pick_supervisor_lead(workers)
  end

  def pick_solo_worker(workers, _text), do: pick_supervisor_lead(workers)

  @doc """
  Pick the worker that ANSWERS a `:chat` message.
  """
  def pick_chat_worker(workers) when is_list(workers) do
    Enum.find_value(["codex", "claude"], fn handle ->
      Enum.find(workers, &(&1.handle == handle))
    end)
  end

  def pick_chat_worker(_), do: nil

  defp ui_flavored_request?(text) when is_binary(text) do
    Regex.match?(
      ~r/\b(ui|ux|css|styl(e|es|ing)|design|landing|hero|animation|animate|frontend|front-end|layout|theme|responsive|tailwind|component|visual|gradient|shader|three\.?js|gsap)\b/i,
      text
    )
  end

  defp ui_flavored_request?(_), do: false

  @doc "Whether team runs default to supervisor mode (one visible lead cell)."
  def team_supervisor_mode? do
    case System.get_env("VIBE_TEAM_MODE") do
      value when is_binary(value) ->
        String.downcase(String.trim(value)) not in ["sequential", "legacy", "chain"]

      _ ->
        true
    end
  end

  @doc """
  Build a team-run prompt for a worker. In supervisor mode the lead owns the
  user-visible reply and sibling workers run focused under-hood slices.
  """
  def build_team_bridge_prompt(
        chat_id,
        worker,
        dispatch_text,
        requester_user_id,
        team_workers,
        team_run_id,
        opts \\ []
      )

  def build_team_bridge_prompt(
        chat_id,
        worker,
        dispatch_text,
        requester_user_id,
        team_workers,
        team_run_id,
        opts
      )
      when is_binary(chat_id) and is_map(worker) and is_binary(dispatch_text) do
    if group_chat?(chat_id) do
      mode = team_mode_from_opts(opts)
      lead_handle = Keyword.get(opts, :lead_worker) || lead_handle_from_workers(team_workers)

      role =
        Keyword.get(opts, :team_role) ||
          if(worker.handle == lead_handle, do: "lead", else: "worker")

      context = group_collaboration_context(chat_id, requester_user_id)
      teammate_names = team_workers_label(team_workers)
      teammate_handles = team_workers_handles(team_workers)
      handoff_path = ".vibe/team/#{safe_team_run_id(team_run_id)}.md"
      default_focus = team_worker_default_focus(worker.handle)
      contract_context = Keyword.get(opts, :contract_context) || ""

      case {mode, role} do
        {_, "chat"} ->
          build_chat_reply_prompt(worker, dispatch_text, context)

        {_, "solo"} ->
          build_solo_visible_prompt(worker, dispatch_text, context)

        {"supervisor", "lead"} ->
          build_supervisor_lead_prompt(
            worker,
            dispatch_text,
            teammate_names,
            teammate_handles,
            handoff_path,
            default_focus,
            team_run_id,
            context
          )

        {"supervisor", _} ->
          build_supervisor_worker_prompt(
            worker,
            dispatch_text,
            teammate_names,
            teammate_handles,
            handoff_path,
            default_focus,
            team_run_id,
            lead_handle,
            contract_context,
            context
          )

        _ ->
          build_sequential_team_prompt(
            worker,
            dispatch_text,
            team_workers,
            teammate_names,
            teammate_handles,
            handoff_path,
            default_focus,
            team_run_id,
            context
          )
      end
    else
      dispatch_text
    end
  end

  def build_team_bridge_prompt(
        _chat_id,
        _worker,
        dispatch_text,
        _requester,
        _workers,
        _run_id,
        _opts
      ),
      do: dispatch_text

  defp build_chat_reply_prompt(worker, dispatch_text, context) do
    """
    You are #{worker.label}, replying to the user in a Vibe chat.

    This is a CONVERSATION, not a work order. The user is asking you something —
    answer it directly and stop. Do not implement anything, do not edit, create or
    delete files, do not run builds, and do not propose a plan of changes unless
    the user asked for one. You have no write access on this turn by design; if
    the request genuinely needs code changed, just say so in one line and let the
    user ask for it.

    Never narrate your own setup: do not mention instruction files, AGENTS.md,
    repo standards, system prompts, or the tools you are using. The user does not
    want to read about your scaffolding — they want the answer.

    If the user shared an image, look at it and describe what you actually see.

    Reply in a sentence or two, plainly, like a person. No headings, no tool logs.

    Shared Vibe group memory:
    #{context_or_empty(context)}

    Message:
    #{dispatch_text}
    """
    |> String.trim()
  end

  defp build_solo_visible_prompt(worker, dispatch_text, context) do
    """
    You are #{worker.label}, handling this Vibe request solo — you are the single
    agent on it, there is no team to coordinate with for this task.

    Do the work end to end and completely: implement every part the request needs,
    with no stubs, no TODO screens, and no "next steps" placeholders. Follow the
    repo's standards in AGENTS.md — including the Premium UI/UX Production Standard
    for any website or frontend work (no generic AI-template scaffold). Make sure
    your work builds before you finish.

    Do not reset, stash, revert, or overwrite pre-existing user changes. Keep your
    final reply concise: what you built and how to run or verify it — no raw tool
    logs.

    If mid-way you find the task is actually large enough to need multiple
    specialists (separate frontend / backend / schema slices), finish what you
    safely can and say so explicitly at the end, so it can be re-run as a full team.

    Shared Vibe group memory:
    #{context_or_empty(context)}

    Request:
    #{dispatch_text}
    """
    |> String.trim()
  end

  defp build_supervisor_lead_prompt(
         worker,
         dispatch_text,
         teammate_names,
         teammate_handles,
         handoff_path,
         default_focus,
         team_run_id,
         context
       ) do
    """
    You are #{worker.label}, the RESPONSIBLE LEAD for a Vibe supervisor team run.

    Team run id: #{team_run_id || "unknown"}
    Teammates running under the hood: #{teammate_names}
    Team handles: #{teammate_handles}
    Your default focus: #{default_focus}
    Shared handoff board: #{handoff_path}

    You are a THIN ORCHESTRATOR. You enhance the request, obtain the plan from the
    advisor, dispatch builders, narrate progress, and synthesize their shared-memory
    handoffs. You do NOT survey repository code, implement a slice, or edit source
    files yourself. The only exception is truly trivial final wiring after every
    reasonable worker assignment is complete.

    Run this strict protocol (the server machine-parses your directives):

    PHASE 0 — ENHANCE. Restate the user's intent internally as a corrected,
    unambiguous implementation brief. Preserve every explicit constraint and scope;
    fix typos, resolve harmless ambiguity with sensible defaults, and record those
    defaults. Narrate briefly that you are refining the request. Do not open source
    files or perform a code survey.

    PHASE 1 — ADVISOR PLAN. Build only a lightweight repository map: directory and
    file paths (for example `rg --files` or a shallow `find`), with no file contents,
    code reading, or architecture investigation. Narrate that you are calling the
    advisor. Call the configured ask_fable MCP advisor with exactly:
      - the enhanced implementation brief;
      - the lightweight path map;
      - the available worker handles #{teammate_handles}; and
      - a request for task_table rows of worker → objective → exact DISJOINT files;
        and a top-level contracts array naming every cross-worker payload/interface
        owner and consumer.
    The advisor is authoritative for decomposition (its runtime already falls back
    Fable → Opus → GPT-5.6-Sol). Convert its answer faithfully into ONE single-line
    directive (stdout/tool log is fine):
      VIBE_TEAM_PLAN: {"version":2,"classification":"team","architecture":"<advisor summary>","contracts":[{"name":"<slug>","owner":"<worker handle>","consumers":["<worker handle>"],"summary":"<what the shape is>"}],"decisions":["<defaults>"],"foundation":{"files":[]},"task_table":[{"worker":"claude","objective":"<what>","files":["<exact disjoint paths>"],"boundaries":"<what NOT to touch>","fallback":"grok"}],"integrator":"#{worker.handle}","verification":["<checks>" ]}
    Never invent a replacement decomposition when the advisor responded. Never put
    @#{worker.handle} in task_table; the lead is not a builder. Every row must name
    concrete files and no file may appear in two rows. Shared/foundation files must
    be assigned to one worker, not retained by the lead. If every advisor fallback
    is unavailable, immediately create the smallest safe disjoint task_table yourself,
    record "advisor unavailable" in decisions, and continue — never block the run.
    For a genuinely non-decomposable build request, still emit `classification:"team"`
    with one worker row; a supervisor lead never turns itself into the solo builder.
    Write the same plan human-readably to #{handoff_path}; this plan/coordination write
    is allowed and is not source implementation.

    PHASE 2 — DISPATCH. Narrate each dispatch (for example, "Calling Claude…",
    then "Claude running"). Emit exactly:
      VIBE_TEAM_SPAWN: <all workers present in the advisor task_table>
    The server uses the validated task_table as the authoritative assignment. Use
    VIBE_TEAM_FOCUS only to add a small clarification; never replace the advisor's
    objective or file ownership.

    PHASE 3 — WAIT + CHECK SHARED MEMORY. Do not take over slow work. Let the server
    monitor true stalls and crashes. Wait for every dispatched row to reach a terminal
    status, then reread ALL `## <worker> — files: ... — status: ...` sections in
    #{handoff_path}. Treat those completed handoffs as the source of truth, not your
    earlier live/transient narration. If a real gap remains, ask the advisor to assign
    a new disjoint worker slice and emit another plan/spawn cycle. You may do only
    trivial final wiring that cannot reasonably be delegated, and must record it.

    PHASE 4 — SUMMARY. After all worker streams are settled and all handoff sections
    have been read, emit the run's only user-facing text: one concise summary of what
    each worker completed, verification performed, and any honest blocker. Base it on
    shared memory, not assumptions. No raw tool logs or directive lines in the summary.

    Always: do not reset, stash, revert, or overwrite pre-existing user changes.
    If you hit a HARD blocker (design ambiguity, a failing approach, a cross-cutting
    decision), call the ask_fable advisor MCP tool before guessing. Do not call it
    for routine work.

    Collaboration rules:
    #{agent_operating_rules(worker, handoff_path)}

    Shared Vibe group memory:
    #{context_or_empty(context)}

    Latest team request:
    #{dispatch_text}
    """
    |> String.trim()
  end

  defp build_supervisor_worker_prompt(
         worker,
         dispatch_text,
         teammate_names,
         teammate_handles,
         handoff_path,
         default_focus,
         team_run_id,
         lead_handle,
         contract_context,
         context
       ) do
    """
    You are #{worker.label} in a Vibe supervisor team run (UNDER THE HOOD).

    Team run id: #{team_run_id || "unknown"}
    Lead (user-visible owner): @#{lead_handle || "lead"}
    Teammates: #{teammate_names}
    Team handles: #{teammate_handles}
    Your focus: #{default_focus}
    Shared handoff board: #{handoff_path}

    #{contract_context}

    Rules:
    - You are NOT posting a chat bubble. The lead synthesizes the user-facing answer.
    - Read #{handoff_path} first (architecture plan + task table). You are a BUILDER
      unless your focus explicitly says review: implement your assigned focus exactly
      and completely — every file listed, fully implemented, no stubs or TODO screens.
    - Stay strictly inside your assigned file list. Shared/foundation files are
      editable only when the advisor assigned those exact paths to your row; the
      lead does not own an implementation slice.
    - Avoid rewriting the whole repo or duplicating the lead.
    - Append ownership, findings, exact files changed, verification, and blockers to
      #{handoff_path}. Do not replace other agents' sections.
    - Completion is not finished until you append exactly one result section headed
      `## #{worker.handle} — files: <comma-separated exact paths> — status: <done|blocked>`
      to #{handoff_path}. Include a concise result and verification beneath it. If the
      file already has your task's section, update only that section idempotently.
    - Do not reset, stash, revert, or overwrite pre-existing user changes.
    - Keep final stdout short (handoff summary only) — not a long user essay.
    - If your work is UI/JSX/frontend, note that for Gemini UI review in the handoff.
    - If a configured advisor is unavailable, continue with best judgment.
    - If you hit a HARD blocker (design ambiguity, a failing approach, a cross-cutting
      decision), call the ask_fable advisor MCP tool before guessing. Do not call it
      for routine work.

    Collaboration rules:
    #{agent_operating_rules(worker, handoff_path)}

    Shared Vibe group memory:
    #{context_or_empty(context)}

    Latest team request:
    #{dispatch_text}
    """
    |> String.trim()
  end

  defp build_sequential_team_prompt(
         worker,
         dispatch_text,
         team_workers,
         teammate_names,
         teammate_handles,
         handoff_path,
         default_focus,
         team_run_id,
         context
       ) do
    worker_index = Enum.find_index(team_workers, &(&1.handle == worker.handle)) || 0
    worker_number = worker_index + 1

    """
    You are #{worker.label} in a Vibe team run.

    Team run id: #{team_run_id || "unknown"}
    Teammates in this run: #{teammate_names}
    Team handles: #{teammate_handles}
    Your step: #{worker_number} of #{length(team_workers)}
    Default focus: #{default_focus}

    The server gives edit ownership to one worker at a time. You currently own
    this step; later workers will build on your result. Read #{handoff_path}
    before editing. Do not reset, stash, revert, or overwrite pre-existing user
    changes. If another worker already owns a file or completed a slice, take a
    non-overlapping slice. Append your ownership, findings, exact files changed,
    verification, blockers, and recommended next owner to the handoff before
    finishing. The first worker should record a short decomposition; later
    workers should update it rather than replace it. If a configured advisor is
    unavailable, record that fact and continue with the executor's best judgment.

    Collaboration rules:
    #{agent_operating_rules(worker, handoff_path)}

    Shared Vibe group memory:
    #{context_or_empty(context)}

    Latest team request:
    #{dispatch_text}
    """
    |> String.trim()
  end

  defp team_mode_from_opts(opts) do
    case Keyword.get(opts, :team_mode) || Keyword.get(opts, :mode) do
      mode when is_binary(mode) -> String.downcase(String.trim(mode))
      _ -> if(team_supervisor_mode?(), do: "supervisor", else: "sequential")
    end
  end

  defp lead_handle_from_workers(workers) when is_list(workers) do
    case pick_supervisor_lead(workers) do
      %{handle: handle} -> handle
      _ -> nil
    end
  end

  defp lead_handle_from_workers(_), do: nil

  @doc """
  Persist a coordinated bridge team run and return the lead worker.
  """
  def register_bridge_team_run(
        chat_id,
        team_run_id,
        workers,
        dispatch_text,
        requester_user_id,
        reply_to_id,
        bridge_metadata,
        opts \\ []
      )

  def register_bridge_team_run(
        chat_id,
        team_run_id,
        workers,
        dispatch_text,
        requester_user_id,
        reply_to_id,
        bridge_metadata,
        opts
      )
      when is_binary(chat_id) and is_binary(team_run_id) and is_list(workers) do
    handles = Enum.map(workers, & &1.handle)
    mode = team_mode_from_opts(opts)

    lead =
      case mode do
        "supervisor" -> pick_supervisor_lead(workers)
        _ -> List.first(workers)
      end

    case {handles, lead} do
      {[], _} ->
        nil

      {_, nil} ->
        nil

      {handles, lead_worker} ->
        lead_handle = lead_worker.handle
        remaining = Enum.reject(handles, &(&1 == lead_handle))
        now_ms = System.system_time(:millisecond)

        worker_states = %{
          lead_handle => %{
            "status" => "running",
            "started_at" => now_ms,
            "finished_at" => nil,
            "summary" => nil,
            "task_id" => nil,
            "last_label" => "starting"
          }
        }

        ensure_team_run_table()

        state = %{
          chat_id: chat_id,
          team_run_id: team_run_id,
          workers: handles,
          remaining: remaining,
          dispatch_text: dispatch_text,
          requester_user_id: requester_user_id,
          reply_to_id: reply_to_id,
          bridge_metadata: bridge_metadata || %{},
          started_at: now_ms,
          mode: mode,
          lead_worker: lead_handle,
          worker_states: worker_states
        }

        case persist_team_run(state, lead_handle) do
          :created ->
            :ets.insert(@team_run_table, {{chat_id, team_run_id}, state})

            if mode in ["supervisor", "solo"] do
              Vibe.AI.TeamRunMonitor.ensure_started(chat_id, team_run_id)
              Vibe.AI.TeamRunMonitor.note_spawned(chat_id, team_run_id, lead_handle, nil)
            end

            lead_worker

          :duplicate ->
            Logger.info(
              "[LocalAgentWorker] duplicate team registration ignored chat=#{chat_id} run=#{team_run_id}"
            )

            nil

          {:error, reason} ->
            Logger.error(
              "[LocalAgentWorker] durable team registration failed; using ETS fallback chat=#{chat_id} run=#{team_run_id} reason=#{inspect(reason)}"
            )

            :ets.insert(@team_run_table, {{chat_id, team_run_id}, state})
            lead_worker
        end
    end
  end

  def register_bridge_team_run(_, _, _, _, _, _, _, _), do: nil

  @doc "Return current worker_states list for a team run (for stream payloads)."
  def team_workers_status(chat_id, team_run_id)
      when is_binary(chat_id) and is_binary(team_run_id) do
    ensure_team_run_table()

    case :ets.lookup(@team_run_table, {chat_id, team_run_id}) do
      [{{^chat_id, ^team_run_id}, state}] ->
        worker_states_to_list(Map.get(state, :worker_states) || %{})

      _ ->
        case Repo.get(TeamRun, team_run_id) do
          %TeamRun{chat_id: ^chat_id, worker_states: states} when is_map(states) ->
            worker_states_to_list(states)

          _ ->
            []
        end
    end
  rescue
    _ -> []
  end

  def team_workers_status(_, _), do: []

  @doc "Update one worker's live status on a team run and return the full status list."
  def update_team_worker_state(chat_id, team_run_id, worker_handle, patch)
      when is_binary(chat_id) and is_binary(team_run_id) and is_binary(worker_handle) and
             is_map(patch) do
    ensure_team_run_table()
    handle = normalize_handle(worker_handle) || worker_handle
    now_ms = System.system_time(:millisecond)

    case :ets.lookup(@team_run_table, {chat_id, team_run_id}) do
      [{{^chat_id, ^team_run_id}, state}] ->
        states = Map.get(state, :worker_states) || %{}
        current = Map.get(states, handle) || %{}

        merged =
          current
          |> Map.merge(stringify_keys(patch))
          |> then(fn m ->
            status = m["status"] || m[:status]

            cond do
              status in ["running", "pending", "starting"] and is_nil(m["started_at"]) ->
                Map.put(m, "started_at", now_ms)

              status in ["done", "failed", "skipped"] and is_nil(m["finished_at"]) ->
                Map.put(m, "finished_at", now_ms)

              true ->
                m
            end
          end)
          |> put_duration_ms()

        new_states = Map.put(states, handle, merged)
        new_state = Map.put(state, :worker_states, new_states)
        :ets.insert(@team_run_table, {{chat_id, team_run_id}, new_state})
        maybe_persist_worker_states(chat_id, team_run_id, new_states)
        worker_states_to_list(new_states)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  def update_team_worker_state(_, _, _, _), do: []

  defp put_duration_ms(state) when is_map(state) do
    started = state["started_at"] || state[:started_at]
    finished = state["finished_at"] || state[:finished_at] || System.system_time(:millisecond)

    if is_integer(started) do
      Map.put(state, "duration_ms", max(0, finished - started))
    else
      state
    end
  end

  defp put_duration_ms(state), do: state

  defp worker_states_to_list(states) when is_map(states) do
    preferred = @worker_order

    handles =
      preferred
      |> Enum.filter(&Map.has_key?(states, &1))
      |> Kernel.++(Map.keys(states) |> Enum.reject(&(&1 in preferred)))

    Enum.map(handles, fn handle ->
      entry = Map.get(states, handle) || %{}
      worker = resolve_handle(handle)

      %{
        "worker" => handle,
        "label" => (worker && worker.label) || handle,
        "status" => entry["status"] || entry[:status] || "pending",
        "startedAt" => entry["started_at"] || entry["startedAt"] || entry[:started_at],
        "finishedAt" => entry["finished_at"] || entry["finishedAt"] || entry[:finished_at],
        "durationMs" => entry["duration_ms"] || entry["durationMs"] || entry[:duration_ms],
        "summary" => entry["summary"] || entry[:summary],
        "taskId" => entry["task_id"] || entry["taskId"] || entry[:task_id],
        "lastLabel" => entry["last_label"] || entry["lastLabel"] || entry[:last_label],
        "progressBytes" =>
          entry["progress_bytes"] || entry["progressBytes"] || entry[:progress_bytes],
        "lastProgressAt" =>
          entry["last_progress_at"] || entry["lastProgressAt"] || entry[:last_progress_at]
      }
    end)
  end

  defp worker_states_to_list(_), do: []

  defp maybe_persist_worker_states(chat_id, team_run_id, states) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(run in TeamRun,
        where: run.id == ^team_run_id and run.chat_id == ^chat_id and run.status == "running"
      ),
      set: [worker_states: states, updated_at: now]
    )

    :ok
  rescue
    _ -> :ok
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp stringify_keys(_), do: %{}

  @doc "Remove stale or completed team sequencing state."
  def clear_bridge_team_run(chat_id, team_run_id) do
    ensure_team_run_table()
    :ets.delete(@team_run_table, {chat_id, team_run_id})
    now = DateTime.utc_now()

    Repo.update_all(
      from(run in TeamRun,
        where: run.id == ^team_run_id and run.chat_id == ^chat_id and run.status == "running"
      ),
      set: [status: "completed", updated_at: now]
    )

    :ok
  rescue
    error ->
      Logger.warning(
        "[LocalAgentWorker] could not finalize durable team run chat=#{chat_id} run=#{team_run_id}: #{Exception.message(error)}"
      )

      :ok
  end

  @doc "Stop a durable team run after its current owner fails; never advance past a missing handoff."
  def fail_bridge_team_run(chat_id, team_run_id, worker_handle, reason)
      when is_binary(chat_id) and is_binary(team_run_id) do
    ensure_team_run_table()
    :ets.delete(@team_run_table, {chat_id, team_run_id})
    now = DateTime.utc_now()
    normalized_worker = normalize_string(worker_handle)

    query =
      from(run in TeamRun,
        where: run.id == ^team_run_id and run.chat_id == ^chat_id and run.status == "running"
      )

    query =
      if is_binary(normalized_worker) do
        from(run in query, where: run.current_worker == ^normalized_worker)
      else
        query
      end

    Repo.update_all(query,
      set: [
        status: "failed",
        last_error: reason |> to_string() |> String.slice(0, 2_000),
        updated_at: now
      ]
    )

    :ok
  rescue
    error ->
      Logger.warning(
        "[LocalAgentWorker] could not fail durable team run chat=#{chat_id} run=#{team_run_id}: #{Exception.message(error)}"
      )

      :ok
  end

  def fail_bridge_team_run(_chat_id, _team_run_id, _worker_handle, _reason), do: :ok

  @doc """
  Cancel a supervisor team run and return cancel targets `{provider, task_id}` for
  every known worker task so the bridge can kill them all.
  """
  def cancel_bridge_team_run(chat_id, team_run_id, requester_user_id \\ nil)

  def cancel_bridge_team_run(chat_id, team_run_id, requester_user_id)
      when is_binary(chat_id) and is_binary(team_run_id) do
    ensure_team_run_table()
    now_ms = System.system_time(:millisecond)

    targets =
      case :ets.lookup(@team_run_table, {chat_id, team_run_id}) do
        [{{^chat_id, ^team_run_id}, state}] ->
          states =
            (Map.get(state, :worker_states) || %{})
            |> Enum.map(fn {handle, entry} ->
              {handle,
               Map.merge(entry || %{}, %{
                 "status" => "cancelled",
                 "finished_at" => now_ms,
                 "last_label" => "cancelled"
               })}
            end)
            |> Map.new()

          new_state =
            state
            |> Map.put(:worker_states, states)
            |> Map.put(:status, "cancelled")

          :ets.insert(@team_run_table, {{chat_id, team_run_id}, new_state})

          Enum.map(states, fn {handle, entry} ->
            %{
              provider: handle,
              task_id: entry["task_id"] || entry["taskId"] || entry[:task_id]
            }
          end)

        _ ->
          []
      end

    now = DateTime.utc_now()

    Repo.update_all(
      from(run in TeamRun,
        where: run.id == ^team_run_id and run.chat_id == ^chat_id and run.status == "running"
      ),
      set: [status: "cancelled", last_error: "cancelled_by_user", updated_at: now]
    )

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-team-worker", %{
      "chatId" => chat_id,
      "teamRunId" => team_run_id,
      "teamMode" => "supervisor",
      "status" => "cancelled",
      "teamWorkersStatus" => team_workers_status(chat_id, team_run_id),
      "suppressVisible" => true
    })

    Vibe.AI.TeamRunMonitor.note_cancelled(chat_id, team_run_id)

    _ = requester_user_id
    targets
  rescue
    error ->
      Logger.warning(
        "[LocalAgentWorker] cancel team run failed chat=#{chat_id} run=#{team_run_id}: #{Exception.message(error)}"
      )

      []
  end

  def cancel_bridge_team_run(_, _, _), do: []

  @doc """
  Spawn under-hood supervisor workers for a lead-requested VIBE_TEAM_SPAWN.
  `handles` are agent handles; optional `focus_by_handle` map of focus strings.
  """
  def spawn_supervisor_workers(
        chat_id,
        team_run_id,
        handles,
        requester_user_id,
        opts \\ []
      )

  def spawn_supervisor_workers(
        chat_id,
        team_run_id,
        handles,
        requester_user_id,
        opts
      )
      when is_binary(chat_id) and is_binary(team_run_id) and is_list(handles) do
    ensure_team_run_table()

    case :ets.lookup(@team_run_table, {chat_id, team_run_id}) do
      [{{^chat_id, ^team_run_id}, state}] ->
        lead = Map.get(state, :lead_worker)
        allowed = MapSet.new(state.workers || [])
        focus_by = Keyword.get(opts, :focus_by_handle) || %{}

        plan =
          Map.get(state, :team_plan) || get_in(state, [:bridge_metadata, "teamPlan"]) || %{}

        spawn_handles =
          handles
          |> Enum.map(&normalize_handle/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.reject(&(&1 == lead))
          |> Enum.filter(&MapSet.member?(allowed, &1))
          |> then(fn hs ->
            if plan["classification"] == "solo" do
              Logger.info(
                "[LocalAgentWorker] solo plan — suppressing spawn of #{inspect(hs)} chat=#{chat_id} run=#{team_run_id}"
              )

              []
            else
              hs
            end
          end)

        contracts = plan_contracts(plan)
        contract_owners = contracts |> Enum.map(& &1["owner"]) |> MapSet.new()

        Enum.each(spawn_handles, fn handle ->
          case resolve_handle(handle) do
            nil ->
              :ok

            worker ->
              existing = get_in(state, [:worker_states, handle, "status"])

              if existing in ["running", "done"] do
                :ok
              else
                task_id = "#{team_run_id}:worker:#{handle}"

                focus =
                  case {plan_focus_for(plan, handle), Map.get(focus_by, handle)} do
                    {nil, nil} -> team_worker_default_focus(handle)
                    {nil, explicit} -> explicit
                    {planned, nil} -> planned
                    {planned, explicit} -> planned <> "\nLead note: " <> explicit
                  end

                consumed = contracts_for_consumer(contracts, handle)

                if contracts != [] and consumed != [] and
                     not MapSet.member?(contract_owners, handle) do
                  waiting_on = List.first(consumed)

                  waiting_label =
                    "waiting for #{waiting_on["name"]} from #{waiting_on["owner"]}"

                  update_team_worker_state(chat_id, team_run_id, handle, %{
                    "status" => "waiting",
                    "task_id" => nil,
                    "last_label" => waiting_label,
                    "focus" => focus,
                    "fallback" => plan_fallback_for(plan, handle)
                  })

                  Logger.info(
                    "[LocalAgentWorker] supervisor contract wait chat=#{chat_id} run=#{team_run_id} worker=#{handle} contract=#{waiting_on["name"]}"
                  )
                else
                  contract_context = contract_prompt_context(contracts, handle, %{})

                  dispatch_supervisor_worker(
                    state,
                    worker,
                    focus,
                    task_id,
                    contract_context,
                    "starting",
                    requester_user_id
                  )
                end
              end
          end
        end)

        :ok

      _ ->
        {:error, :team_run_not_found}
    end
  rescue
    error ->
      Logger.error(
        "[LocalAgentWorker] spawn_supervisor_workers crashed: #{Exception.message(error)}"
      )

      {:error, error}
  end

  def spawn_supervisor_workers(_, _, _, _, _), do: {:error, :invalid}

  defp dispatch_supervisor_worker(
         state,
         worker,
         focus,
         task_id,
         contract_context,
         starting_label,
         requester_user_id
       ) do
    chat_id = state.chat_id
    team_run_id = state.team_run_id
    mode = Map.get(state, :mode) || "supervisor"
    lead = Map.get(state, :lead_worker)

    team_workers =
      (state.workers || [])
      |> Enum.map(&resolve_handle/1)
      |> Enum.reject(&is_nil/1)

    update_team_worker_state(chat_id, team_run_id, worker.handle, %{
      "status" => "running",
      "task_id" => task_id,
      "last_label" => starting_label,
      "focus" => focus,
      "fallback" => plan_fallback_for(run_state_plan(state), worker.handle),
      "contract_context" => contract_context
    })

    prompt =
      build_team_bridge_prompt(
        chat_id,
        worker,
        state.dispatch_text <> "\n\nAssigned focus for this spawn: #{focus}",
        requester_user_id,
        team_workers,
        team_run_id,
        team_mode: mode,
        lead_worker: lead,
        team_role: "worker",
        contract_context: contract_context
      )

    task_payload =
      %{
        "provider" => worker.handle,
        "chatId" => chat_id,
        "taskId" => task_id,
        "prompt" => prompt,
        "replyToId" => state.reply_to_id,
        "requesterUserId" => requester_user_id,
        "teamMode" => mode,
        "teamRunId" => team_run_id,
        "teamWorker" => worker.handle,
        "teamWorkers" => Enum.map(team_workers, & &1.handle),
        "leadWorker" => lead,
        "teamRole" => "worker",
        "suppressVisible" => true
      }
      |> Map.merge(resolve_provider_model(state.bridge_metadata || %{}, worker.handle))

    broadcast_activity(
      chat_id,
      worker.agent_user_id,
      "#{worker.label} joining team run...",
      "running"
    )

    case AgentBridge.dispatch_task(requester_user_id, task_payload) do
      :ok ->
        Vibe.AI.TeamRunMonitor.note_spawned(chat_id, team_run_id, worker.handle, task_id)

        Logger.info(
          "[LocalAgentWorker] supervisor spawn chat=#{chat_id} run=#{team_run_id} worker=#{worker.handle}"
        )

        :ok

      {:error, reason} ->
        update_team_worker_state(chat_id, team_run_id, worker.handle, %{
          "status" => "failed",
          "last_label" => "spawn failed",
          "summary" => inspect(reason)
        })

        stop_activity(chat_id, worker.agent_user_id)

        Logger.warning(
          "[LocalAgentWorker] supervisor spawn failed chat=#{chat_id} worker=#{worker.handle} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp plan_contracts(plan) when is_map(plan) do
    case plan["contracts"] do
      contracts when is_list(contracts) -> contracts
      _ -> []
    end
  end

  defp plan_contracts(_), do: []

  defp contracts_for_consumer(contracts, handle) do
    Enum.filter(contracts, &(handle in List.wrap(&1["consumers"])))
  end

  defp contract_prompt_context(contracts, handle, frozen_contracts) do
    owned = Enum.filter(contracts, &(&1["owner"] == handle))
    consumed = contracts_for_consumer(contracts, handle)

    owner_instruction =
      if owned == [] do
        nil
      else
        "If your slice emits a payload/interface another worker renders or parses, " <>
          "DECIDE AND FREEZE its shape FIRST. Post `## CONTRACT:<name> — owner: <you> — " <>
          "status: frozen` plus the exact shape to the handoff board BEFORE implementing " <>
          "the rest, so consumers can start."
      end

    frozen_blocks =
      consumed
      |> Enum.flat_map(fn contract ->
        case frozen_contracts[contract["name"]] do
          shape when is_binary(shape) ->
            [
              "Frozen payload contract #{contract["name"]}:\n#{shape}\n" <>
                "Match this shape exactly; do not invent fields."
            ]

          _ ->
            []
        end
      end)

    consumer_instruction =
      if consumed == [] do
        nil
      else
        "Your frozen payload contract(s) are injected above; match them exactly, do not " <>
          "invent fields; if a field is missing, note it in the board."
      end

    [owner_instruction | frozen_blocks ++ [consumer_instruction]]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join("\n\n")
  end


  @doc "Monitor: ets-then-DB run state; rewarms the ets cache on DB fallback."
  def fetch_supervisor_run_state(chat_id, team_run_id)
      when is_binary(chat_id) and is_binary(team_run_id) do
    ensure_team_run_table()

    case :ets.lookup(@team_run_table, {chat_id, team_run_id}) do
      [{{^chat_id, ^team_run_id}, state}] ->
        state

      _ ->
        case Repo.get(TeamRun, team_run_id) do
          %TeamRun{chat_id: run_chat} = run ->
            if to_string(run_chat) == chat_id do
              state = durable_team_state(run)
              :ets.insert(@team_run_table, {{chat_id, team_run_id}, state})
              state
            end

          _ ->
            nil
        end
    end
  rescue
    _ -> nil
  end

  def fetch_supervisor_run_state(_, _), do: nil

  @doc "Monitor: normalized payload contracts for a supervisor run."
  def team_contracts(chat_id, team_run_id) do
    case fetch_supervisor_run_state(chat_id, team_run_id) do
      state when is_map(state) -> state |> run_state_plan() |> plan_contracts()
      _ -> []
    end
  end

  @doc """
  Monitor: reread the handoff board, freeze explicit/fallback contracts, and release every
  waiting consumer whose complete contract set is frozen. `fallback_owners` is decided by.
  """
  def monitor_contract_barrier(chat_id, team_run_id, fallback_owners)
      when is_binary(chat_id) and is_binary(team_run_id) do
    with state when is_map(state) <- fetch_supervisor_run_state(chat_id, team_run_id) do
      contracts = state |> run_state_plan() |> plan_contracts()

      if contracts == [] do
        {:ok, []}
      else
        board = read_handoff_board(state)
        fallback_set = fallback_owners |> List.wrap() |> MapSet.new()
        persisted = frozen_contracts_from_state(state)

        frozen =
          Enum.reduce(contracts, persisted, fn contract, acc ->
            name = contract["name"]

            cond do
              is_binary(acc[name]) ->
                acc

              shape = frozen_contract_body(board, contract) ->
                Map.put(acc, name, shape)

              MapSet.member?(fallback_set, contract["owner"]) ->
                shape = fallback_contract_body(board, contract)

                Logger.warning(
                  "[TeamRunMonitor] contract fallback freeze chat=#{chat_id} run=#{team_run_id} " <>
                    "contract=#{name} owner=#{contract["owner"]}"
                )

                Map.put(acc, name, shape)

              true ->
                acc
            end
          end)

        if frozen != persisted, do: persist_frozen_contracts(state, frozen)

        released =
          contracts
          |> Enum.flat_map(&List.wrap(&1["consumers"]))
          |> Enum.uniq()
          |> Enum.filter(fn handle ->
            required = contracts_for_consumer(contracts, handle)

            status =
              get_in(fetch_supervisor_run_state(chat_id, team_run_id), [
                :worker_states,
                handle,
                "status"
              ])

            status == "waiting" and
              Enum.all?(required, &is_binary(frozen[&1["name"]]))
          end)
          |> Enum.filter(fn handle ->
            state = fetch_supervisor_run_state(chat_id, team_run_id)
            worker = resolve_handle(handle)

            if is_map(state) and is_map(worker) do
              focus =
                stored_worker_focus(state, handle) ||
                  plan_focus_for(run_state_plan(state), handle) ||
                  team_worker_default_focus(handle)

              task_id = "#{team_run_id}:worker:#{handle}"
              contract_context = contract_prompt_context(contracts, handle, frozen)

              case dispatch_supervisor_worker(
                     state,
                     worker,
                     focus,
                     task_id,
                     contract_context,
                     "contracts frozen",
                     state.requester_user_id
                   ) do
                :ok -> true
                _ -> false
              end
            else
              false
            end
          end)

        {:ok, released}
      end
    else
      _ -> {:error, :not_found}
    end
  rescue
    error ->
      Logger.warning(
        "[TeamRunMonitor] contract barrier failed chat=#{chat_id} run=#{team_run_id}: " <>
          Exception.message(error)
      )

      {:error, error}
  end

  def monitor_contract_barrier(_, _, _), do: {:error, :invalid}

  defp frozen_contracts_from_state(state) do
    value =
      Map.get(state, :frozen_contracts) ||
        get_in(state, [:bridge_metadata, "frozenContracts"])

    if is_map(value), do: value, else: %{}
  end

  defp persist_frozen_contracts(state, frozen) do
    metadata = Map.put(state.bridge_metadata || %{}, "frozenContracts", frozen)

    updated_state =
      state
      |> Map.put(:bridge_metadata, metadata)
      |> Map.put(:frozen_contracts, frozen)

    :ets.insert(@team_run_table, {{state.chat_id, state.team_run_id}, updated_state})

    case Repo.get(TeamRun, state.team_run_id) do
      %TeamRun{} = run ->
        durable_metadata = Map.put(run.bridge_metadata || %{}, "frozenContracts", frozen)

        run
        |> TeamRun.changeset(%{bridge_metadata: durable_metadata})
        |> Repo.update()

      _ ->
        :ok
    end

    :ok
  end

  defp read_handoff_board(state) do
    metadata = state.bridge_metadata || %{}

    roots =
      [
        metadata["cwd"],
        metadata["repoPath"],
        metadata["agentBridgeCwd"],
        metadata["agentBridgeRepoPath"],
        System.get_env("VIBE_AGENT_WORKER_CWD"),
        File.cwd!(),
        Path.expand("..", File.cwd!()),
        Path.expand("../../../..", __DIR__)
      ]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    relative = Path.join([".vibe", "team", "#{safe_team_run_id(state.team_run_id)}.md"])

    Enum.find_value(roots, "", fn root ->
      case File.read(Path.join(root, relative)) do
        {:ok, body} -> body
        _ -> nil
      end
    end)
  rescue
    _ -> ""
  end

  defp frozen_contract_body(board, contract) do
    board
    |> board_sections()
    |> Enum.find_value(fn {heading, body} ->
      case Regex.run(
             ~r/^CONTRACT:([A-Za-z0-9_.-]+)\s+—\s+owner:\s*([^\s]+)\s+—\s+status:\s*frozen\s*$/iu,
             String.trim(heading)
           ) do
        [_, name, owner] ->
          if name == contract["name"] and normalize_handle(owner) == contract["owner"] do
            normalized_contract_body(body, contract)
          end

        _ ->
          nil
      end
    end)
  end

  defp fallback_contract_body(board, contract) do
    owner = contract["owner"]

    body =
      board
      |> board_sections()
      |> Enum.filter(fn {heading, _body} ->
        Regex.match?(~r/^#{Regex.escape(owner)}\s+—\s+files:/iu, String.trim(heading))
      end)
      |> List.last()
      |> case do
        {_heading, section_body} -> String.trim(section_body)
        _ -> ""
      end

    if body == "" do
      "@#{owner} did not post an explicit contract; proceed with best judgment."
    else
      body
    end
  end

  defp normalized_contract_body(body, contract) do
    case String.trim(body) do
      "" ->
        "@#{contract["owner"]} froze #{contract["name"]} without a shape; proceed with best judgment."

      shape ->
        shape
    end
  end

  defp board_sections(board) when is_binary(board) do
    Regex.scan(~r/^##[ \t]+([^\n]+)\n?(.*?)(?=^##[ \t]+|\z)/msu, board)
    |> Enum.map(fn [_, heading, body] -> {heading, body} end)
  end

  defp board_sections(_), do: []

  @doc "Monitor: mark a worker with a status + note and broadcast the transition."
  def monitor_mark_worker(chat_id, team_run_id, handle, status, note) do
    status_list =
      update_team_worker_state(chat_id, team_run_id, handle, %{
        "status" => status,
        "last_label" => String.slice(note || status, 0, 80),
        "summary" => note
      })

    broadcast_monitor_transition(chat_id, team_run_id, handle, status, note, status_list)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Monitor: cancel whatever is (or is not) still running for a stalled/crashed
  worker and restart its slice FRESH on the same provider with a new task id.
  """
  def monitor_retry_worker(chat_id, team_run_id, handle, reason) do
    with state when is_map(state) <- fetch_supervisor_run_state(chat_id, team_run_id),
         worker when not is_nil(worker) <- resolve_handle(handle) do
      current_status = get_in(state, [:worker_states, handle, "status"])

      if reason == "stalled" and current_status != "running" do
        {:error, :stale}
      else
        old_task_id = get_in(state, [:worker_states, handle, "task_id"])
        cancel_monitor_task(state, handle, old_task_id)

        task_id = "#{team_run_id}:worker:#{handle}:r#{System.unique_integer([:positive])}"

        focus =
          stored_worker_focus(state, handle) ||
            plan_focus_for(run_state_plan(state), handle) ||
            team_worker_default_focus(handle)

        status_list =
          update_team_worker_state(chat_id, team_run_id, handle, %{
            "status" => "running",
            "task_id" => task_id,
            "last_label" => "retrying (#{reason})",
            "focus" => focus
          })

        broadcast_monitor_transition(
          chat_id,
          team_run_id,
          handle,
          "retrying",
          "restarted after #{reason}",
          status_list
        )

        monitor_dispatch_worker(
          state,
          worker,
          focus,
          task_id,
          nil,
          stored_worker_contract_context(state, handle)
        )
      end
    else
      _ -> {:error, :not_found}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  Monitor: a usage-limited worker's slice restarts fresh on an idle provider from the same run
  roster (never mid-task context handoff).
  """
  def monitor_reassign_worker(chat_id, team_run_id, handle) do
    with state when is_map(state) <- fetch_supervisor_run_state(chat_id, team_run_id),
         fallback when is_binary(fallback) <- pick_idle_fallback(state, handle),
         worker when not is_nil(worker) <- resolve_handle(fallback) do
      old_task_id = get_in(state, [:worker_states, handle, "task_id"])
      cancel_monitor_task(state, handle, old_task_id)

      focus =
        stored_worker_focus(state, handle) ||
          plan_focus_for(run_state_plan(state), handle) ||
          team_worker_default_focus(handle)

      task_id = "#{team_run_id}:worker:#{fallback}:x#{System.unique_integer([:positive])}"

      update_team_worker_state(chat_id, team_run_id, handle, %{
        "status" => "reassigned",
        "last_label" => "usage limit → @#{fallback}"
      })

      status_list =
        update_team_worker_state(chat_id, team_run_id, fallback, %{
          "status" => "running",
          "task_id" => task_id,
          "last_label" => "covering @#{handle}",
          "focus" => focus
        })

      broadcast_monitor_transition(
        chat_id,
        team_run_id,
        fallback,
        "reassigned",
        "covering @#{handle} after usage limit",
        status_list
      )

      case monitor_dispatch_worker(
             state,
             worker,
             focus,
             task_id,
             "You are covering @#{handle}'s slice from scratch after a usage limit; " <>
               "their partial work may or may not exist on disk — verify before building on it.",
             stored_worker_contract_context(state, handle)
           ) do
        :ok -> {:ok, fallback}
        error -> error
      end
    else
      nil -> {:error, :no_fallback}
      _ -> {:error, :no_fallback}
    end
  rescue
    error -> {:error, error}
  end

  @doc "Monitor: finalize the run row once every worker state is terminal."
  def monitor_finalize_run(chat_id, team_run_id) do
    statuses =
      team_workers_status(chat_id, team_run_id)
      |> Enum.map(&(&1["status"] || &1[:status]))

    final =
      cond do
        statuses == [] -> nil
        Enum.all?(statuses, &(&1 in ["failed", "cancelled"])) -> "failed"
        true -> "completed"
      end

    with true <- is_binary(final),
         %TeamRun{status: "running"} = run <- Repo.get(TeamRun, team_run_id) do
      run
      |> TeamRun.changeset(%{status: final})
      |> Repo.update()
    end

    :ok
  rescue
    _ -> :ok
  end

  defp monitor_dispatch_worker(state, worker, focus, task_id, cover_note, contract_context) do
    chat_id = state.chat_id
    team_run_id = state.team_run_id
    mode = Map.get(state, :mode) || "supervisor"
    lead = Map.get(state, :lead_worker)

    team_workers =
      (state.workers || [])
      |> Enum.map(&resolve_handle/1)
      |> Enum.reject(&is_nil/1)

    dispatch_text =
      case cover_note do
        note when is_binary(note) and note != "" ->
          state.dispatch_text <> "\n\n" <> note

        _ ->
          state.dispatch_text
      end

    prompt =
      build_team_bridge_prompt(
        chat_id,
        worker,
        dispatch_text <> "\n\nAssigned focus for this spawn: #{focus}",
        state.requester_user_id,
        team_workers,
        team_run_id,
        team_mode: mode,
        lead_worker: lead,
        team_role: "worker",
        contract_context: contract_context
      )

    task_payload =
      %{
        "provider" => worker.handle,
        "chatId" => chat_id,
        "taskId" => task_id,
        "prompt" => prompt,
        "replyToId" => state.reply_to_id,
        "requesterUserId" => state.requester_user_id,
        "teamMode" => mode,
        "teamRunId" => team_run_id,
        "teamWorker" => worker.handle,
        "teamWorkers" => Enum.map(team_workers, & &1.handle),
        "leadWorker" => lead,
        "teamRole" => "worker",
        "suppressVisible" => true
      }
      |> Map.merge(resolve_provider_model(state.bridge_metadata || %{}, worker.handle))

    case AgentBridge.dispatch_task(state.requester_user_id, task_payload) do
      :ok ->
        Vibe.AI.TeamRunMonitor.note_spawned(chat_id, team_run_id, worker.handle, task_id)
        :ok

      {:error, reason} ->
        Logger.warning(
          "[LocalAgentWorker] monitor dispatch failed chat=#{chat_id} worker=#{worker.handle} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp cancel_monitor_task(state, handle, task_id) do
    payload =
      %{
        "action" => "cancel",
        "provider" => handle,
        "chatId" => state.chat_id,
        "requesterUserId" => state.requester_user_id,
        "teamRunId" => state.team_run_id
      }
      |> then(fn map ->
        if is_binary(task_id) and task_id != "", do: Map.put(map, "taskId", task_id), else: map
      end)

    AgentBridge.dispatch_control(state.requester_user_id, payload)
    :ok
  rescue
    _ -> :ok
  end

  defp stored_worker_focus(state, handle) do
    case get_in(state, [:worker_states, handle, "focus"]) do
      focus when is_binary(focus) and focus != "" -> focus
      _ -> nil
    end
  end

  defp stored_worker_contract_context(state, handle) do
    case get_in(state, [:worker_states, handle, "contract_context"]) do
      context when is_binary(context) -> context
      _ -> ""
    end
  end

  defp run_state_plan(state) do
    Map.get(state, :team_plan) || get_in(state, [:bridge_metadata, "teamPlan"]) || %{}
  end

  defp pick_idle_fallback(state, limited_handle) do
    lead = Map.get(state, :lead_worker)
    states = Map.get(state, :worker_states) || %{}

    candidates =
      (state.workers || [])
      |> Enum.reject(&(&1 == limited_handle or &1 == lead))

    idle? = fn handle ->
      get_in(states, [handle, "status"]) in [nil, "pending", "done"]
    end

    planned =
      case get_in(states, [limited_handle, "fallback"]) do
        fallback when is_binary(fallback) ->
          if fallback in candidates and idle?.(fallback), do: fallback

        _ ->
          nil
      end

    by_status = fn wanted ->
      Enum.find(candidates, fn handle ->
        get_in(states, [handle, "status"]) in wanted
      end)
    end

    planned || by_status.([nil, "pending"]) || by_status.(["done"])
  end

  defp broadcast_monitor_transition(chat_id, team_run_id, handle, status, note, status_list) do
    worker = resolve_handle(handle)

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-team-worker", %{
      "chatId" => chat_id,
      "teamRunId" => team_run_id,
      "teamWorker" => handle,
      "agentUserId" => worker && worker.agent_user_id,
      "agentName" => (worker && worker.label) || handle,
      "status" => status,
      "summary" => String.slice(note || "", 0, 400),
      "teamWorkersStatus" => status_list,
      "suppressVisible" => true,
      "monitor" => true
    })

    :ok
  rescue
    _ -> :ok
  end

  @doc "Parse VIBE_TEAM_SPAWN / VIBE_TEAM_FOCUS lines from agent output."
  def parse_team_spawn_directive(text) when is_binary(text) do
    spawn_handles =
      Regex.scan(~r/VIBE_TEAM_SPAWN\s*:\s*([^\n\r]+)/i, text)
      |> Enum.flat_map(fn [_, raw] ->
        raw
        |> String.split(~r/[,;\s]+/, trim: true)
        |> Enum.map(&normalize_handle/1)
        |> Enum.reject(&is_nil/1)
      end)
      |> Enum.uniq()

    focus_by =
      Regex.scan(~r/VIBE_TEAM_FOCUS\s*:\s*([^\n\r]+)/i, text)
      |> Enum.reduce(%{}, fn [_, raw], acc ->
        raw
        |> String.split(~r/[;|]/, trim: true)
        |> Enum.reduce(acc, fn part, inner ->
          case String.split(part, "=", parts: 2) do
            [handle, focus] ->
              case normalize_handle(String.trim(handle)) do
                nil -> inner
                h -> Map.put(inner, h, String.trim(focus))
              end

            _ ->
              inner
          end
        end)
      end)

    if spawn_handles == [] do
      nil
    else
      %{handles: spawn_handles, focus_by_handle: focus_by}
    end
  end

  def parse_team_spawn_directive(_), do: nil

  @doc """
  Parse and validate a lead-emitted `VIBE_TEAM_PLAN: {json}` directive line
  (team-architecture-v2 §2).
  """
  def parse_team_plan_directive(line, roster_handles) when is_binary(line) do
    case Regex.run(~r/VIBE_TEAM_PLAN\s*:\s*(\{.*\})\s*$/i, line) do
      [_, raw] ->
        case Jason.decode(raw) do
          {:ok, plan} when is_map(plan) -> validate_team_plan(plan, roster_handles)
          _ -> {:error, ["plan is not valid JSON"]}
        end

      _ ->
        nil
    end
  end

  def parse_team_plan_directive(_, _), do: nil

  defp validate_team_plan(plan, roster_handles) do
    roster = MapSet.new(roster_handles || [])
    classification = plan["classification"]

    with {:ok, plan} <- normalize_plan_contracts(plan, roster) do
      validate_team_plan_rows(plan, roster, classification)
    end
  end

  defp validate_team_plan_rows(plan, roster, classification) do
    cond do
      classification == "solo" ->
        {:ok, plan}

      classification != "team" ->
        {:error, ["classification must be \"team\" or \"solo\""]}

      true ->
        rows = List.wrap(plan["task_table"])

        row_handles =
          rows
          |> Enum.map(&normalize_handle(&1["worker"]))
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        errors =
          []
          |> then(fn errs ->
            if rows == [], do: ["task_table is empty" | errs], else: errs
          end)
          |> then(fn errs ->
            rows
            |> Enum.with_index()
            |> Enum.reduce(errs, fn {row, idx}, acc ->
              handle = normalize_handle(row["worker"])
              files = row["files"] |> List.wrap() |> Enum.filter(&is_binary/1)

              acc
              |> then(fn a ->
                if handle && MapSet.member?(roster, handle),
                  do: a,
                  else: ["row #{idx}: unknown worker #{inspect(row["worker"])}" | a]
              end)
              |> then(fn a ->
                if files == [], do: ["row #{idx}: files list is empty" | a], else: a
              end)
            end)
          end)
          |> then(fn errs ->
            dupes =
              rows
              |> Enum.flat_map(&List.wrap(&1["files"]))
              |> Enum.filter(&is_binary/1)
              |> Enum.frequencies()
              |> Enum.filter(fn {_, n} -> n > 1 end)
              |> Enum.map(&elem(&1, 0))

            if dupes != [] do
              Logger.warning("[LocalAgentWorker] team plan overlapping files: #{inspect(dupes)}")
              ["task_table files overlap: #{Enum.join(dupes, ", ")}" | errs]
            else
              errs
            end
          end)
          |> then(fn errs ->
            Enum.reduce(plan["contracts"], errs, fn contract, acc ->
              participants = [contract["owner"] | contract["consumers"]]

              participants
              |> Enum.reject(&MapSet.member?(row_handles, &1))
              |> Enum.reduce(acc, fn handle, inner ->
                ["contract #{contract["name"]}: worker #{handle} has no task_table row" | inner]
              end)
            end)
          end)

        if errors == [], do: {:ok, plan}, else: {:error, Enum.reverse(errors)}
    end
  end

  defp normalize_plan_contracts(plan, roster) do
    case Map.fetch(plan, "contracts") do
      :error ->
        {:ok, Map.put(plan, "contracts", [])}

      {:ok, nil} ->
        {:ok, Map.put(plan, "contracts", [])}

      {:ok, contracts} when is_list(contracts) ->
        {normalized, errors} =
          contracts
          |> Enum.with_index()
          |> Enum.reduce({[], []}, fn {contract, idx}, {items, errs} ->
            case normalize_plan_contract(contract, idx, roster) do
              {:ok, item} -> {[item | items], errs}
              {:error, reasons} -> {items, reasons ++ errs}
            end
          end)

        duplicate_names =
          normalized
          |> Enum.map(& &1["name"])
          |> Enum.frequencies()
          |> Enum.filter(fn {_name, count} -> count > 1 end)
          |> Enum.map(&elem(&1, 0))

        errors =
          if duplicate_names == [],
            do: errors,
            else: ["duplicate contract names: #{Enum.join(duplicate_names, ", ")}" | errors]

        if errors == [] do
          {:ok, Map.put(plan, "contracts", Enum.reverse(normalized))}
        else
          {:error, Enum.reverse(errors)}
        end

      {:ok, _} ->
        {:error, ["contracts must be an array"]}
    end
  end

  defp normalize_plan_contract(contract, idx, roster) when is_map(contract) do
    name = normalize_string(contract["name"])
    owner = normalize_handle(contract["owner"])
    consumers_value = contract["consumers"]

    consumers =
      if is_list(consumers_value) do
        consumers_value
        |> Enum.map(&normalize_handle/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
      else
        []
      end

    errors =
      []
      |> then(fn errs ->
        if is_binary(name) and Regex.match?(~r/^[A-Za-z0-9_.-]+$/, name),
          do: errs,
          else: ["contract #{idx}: name must be a non-empty slug" | errs]
      end)
      |> then(fn errs ->
        if is_binary(owner) and MapSet.member?(roster, owner),
          do: errs,
          else: ["contract #{idx}: unknown owner #{inspect(contract["owner"])}" | errs]
      end)
      |> then(fn errs ->
        if is_list(consumers_value) and consumers != [],
          do: errs,
          else: ["contract #{idx}: consumers must be a non-empty array" | errs]
      end)
      |> then(fn errs ->
        unknown = Enum.reject(consumers, &MapSet.member?(roster, &1))

        if unknown == [],
          do: errs,
          else: ["contract #{idx}: unknown consumers #{Enum.join(unknown, ", ")}" | errs]
      end)

    if errors == [] do
      {:ok,
       %{
         "name" => name,
         "owner" => owner,
         "consumers" => consumers,
         "summary" => normalize_string(contract["summary"]) || ""
       }}
    else
      {:error, errors}
    end
  end

  defp normalize_plan_contract(_contract, idx, _roster),
    do: {:error, ["contract #{idx}: entry must be an object"]}

  @doc "Store a validated plan on the run (ets + durable bridge_metadata)."
  def store_team_plan(chat_id, team_run_id, plan)
      when is_binary(chat_id) and is_binary(team_run_id) and is_map(plan) do
    ensure_team_run_table()

    case :ets.lookup(@team_run_table, {chat_id, team_run_id}) do
      [{{^chat_id, ^team_run_id}, state}] ->
        :ets.insert(@team_run_table, {{chat_id, team_run_id}, Map.put(state, :team_plan, plan)})

      _ ->
        :ok
    end

    case Repo.get(TeamRun, team_run_id) do
      %TeamRun{} = run ->
        metadata = Map.put(run.bridge_metadata || %{}, "teamPlan", plan)

        run
        |> TeamRun.changeset(%{bridge_metadata: metadata})
        |> Repo.update()

      _ ->
        :ok
    end

    Logger.info(
      "[LocalAgentWorker] team plan stored chat=#{chat_id} run=#{team_run_id} " <>
        "class=#{plan["classification"]} rows=#{length(List.wrap(plan["task_table"]))}"
    )

    :ok
  rescue
    error ->
      Logger.warning("[LocalAgentWorker] store_team_plan failed: #{Exception.message(error)}")
      :ok
  end

  def store_team_plan(_, _, _), do: :ok

  @doc "Roster handles for a run (for plan validation at the channel)."
  def team_run_roster(chat_id, team_run_id) do
    case fetch_supervisor_run_state(chat_id, team_run_id) do
      %{workers: workers} when is_list(workers) -> workers
      _ -> []
    end
  end

  defp plan_focus_for(plan, handle) do
    plan
    |> Map.get("task_table")
    |> List.wrap()
    |> Enum.find(fn row -> normalize_handle(row["worker"]) == handle end)
    |> case do
      nil ->
        nil

      row ->
        files = row["files"] |> List.wrap() |> Enum.filter(&is_binary/1)

        [
          row["objective"] && "Objective: #{row["objective"]}",
          files != [] && "Files (yours alone, implement completely): #{Enum.join(files, ", ")}",
          row["boundaries"] && "Boundaries: #{row["boundaries"]}"
        ]
        |> Enum.filter(&is_binary/1)
        |> Enum.join("\n")
    end
  end

  defp plan_fallback_for(plan, handle) do
    plan
    |> Map.get("task_table")
    |> List.wrap()
    |> Enum.find(fn row -> normalize_handle(row["worker"]) == handle end)
    |> case do
      %{"fallback" => fallback} -> normalize_handle(fallback)
      _ -> nil
    end
  end

  @doc """
  On bridge reconnect, mark matching team workers as running again from status
  payloads so the lead strip recovers mid-run.
  """
  def rehydrate_team_workers_from_running_tasks(chat_id, running_tasks)
      when is_binary(chat_id) and is_list(running_tasks) do
    Enum.each(running_tasks, fn task ->
      team_run_id =
        normalize_string(
          task["teamRunId"] || task[:teamRunId] || task["team_run_id"] || task[:team_run_id]
        )

      worker =
        normalize_string(
          task["teamWorker"] || task[:teamWorker] || task["provider"] || task[:provider]
        )

      task_id = normalize_string(task["taskId"] || task[:taskId] || task["task_id"])

      if is_binary(team_run_id) and is_binary(worker) do
        update_team_worker_state(chat_id, team_run_id, worker, %{
          "status" => "running",
          "task_id" => task_id,
          "last_label" => "reconnected"
        })
      end
    end)

    :ok
  end

  def rehydrate_team_workers_from_running_tasks(_, _), do: :ok

  defp persist_team_run(state, first_worker) do
    attrs = %{
      id: state.team_run_id,
      chat_id: state.chat_id,
      requester_user_id: state.requester_user_id,
      computer_id: state.bridge_metadata["computerId"],
      reply_to_id: state.reply_to_id,
      workers: state.workers,
      current_index: 0,
      current_worker: first_worker,
      mode: Map.get(state, :mode) || "supervisor",
      lead_worker: Map.get(state, :lead_worker) || first_worker,
      worker_states: Map.get(state, :worker_states) || %{},
      status: "running",
      dispatch_ciphertext: AgentMessageCrypto.encrypt_for_storage(state.dispatch_text),
      bridge_metadata: state.bridge_metadata
    }

    %TeamRun{}
    |> TeamRun.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _run} ->
        :created

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :id),
          do: :duplicate,
          else: {:error, changeset}
    end
  rescue
    error -> {:error, error}
  end

  defp advance_durable_team_run(chat_id, team_run_id, completed_handle) do
    Repo.transaction(fn ->
      run =
        Repo.one(
          from(run in TeamRun,
            where: run.id == ^team_run_id and run.chat_id == ^chat_id,
            lock: "FOR UPDATE"
          )
        )

      cond do
        is_nil(run) ->
          {:error, :not_found}

        run.status != "running" ->
          :done

        run.current_worker != completed_handle ->
          :noop

        true ->
          next_index = run.current_index + 1

          case Enum.at(run.workers, next_index) do
            nil ->
              run
              |> TeamRun.changeset(%{status: "completed"})
              |> Repo.update!()

              :done

            next_handle ->
              updated =
                run
                |> TeamRun.changeset(%{
                  current_index: next_index,
                  current_worker: next_handle,
                  status: "running"
                })
                |> Repo.update!()

              {:next, durable_team_state(updated), next_handle}
          end
      end
    end)
    |> case do
      {:ok, value} -> value
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp durable_team_state(%TeamRun{} = run) do
    %{
      chat_id: to_string(run.chat_id),
      team_run_id: to_string(run.id),
      workers: run.workers || [],
      remaining: Enum.drop(run.workers || [], run.current_index + 1),
      dispatch_text: AgentMessageCrypto.decrypt_from_storage(run.dispatch_ciphertext || ""),
      requester_user_id: to_string(run.requester_user_id),
      reply_to_id: run.reply_to_id,
      bridge_metadata: run.bridge_metadata || %{},
      started_at: DateTime.to_unix(run.inserted_at, :millisecond),
      mode: run.mode || "sequential",
      lead_worker: run.lead_worker || run.current_worker,
      worker_states: run.worker_states || %{}
    }
  end

  @doc "Record a human's prompt to a worker into the shared group memory (no-op in DMs)."
  def note_bridge_user_turn(chat_id, worker, text, requester_user_id)
      when is_binary(chat_id) and is_map(worker) do
    if group_chat?(chat_id) do
      GroupAgentMemory.append_message(
        chat_id,
        %{
          "role" => "user",
          "content" => clean_for_memory(text),
          "user_id" => requester_user_id,
          "sender_name" => sender_display_name(requester_user_id),
          "target_agent" => worker.handle
        },
        acting_user_id: requester_user_id
      )
    end

    :ok
  end

  def note_bridge_user_turn(_chat_id, _worker, _text, _requester), do: :ok

  @doc "Record a human team request once, instead of once per dispatched worker."
  def note_bridge_team_user_turn(chat_id, workers, text, requester_user_id, team_run_id)
      when is_binary(chat_id) and is_list(workers) do
    if group_chat?(chat_id) do
      GroupAgentMemory.append_message(
        chat_id,
        %{
          "role" => "user",
          "content" => clean_for_memory(strip_team_trigger(text)),
          "user_id" => requester_user_id,
          "sender_name" => sender_display_name(requester_user_id),
          "target_agent" => "team",
          "target_agents" => Enum.map(workers, & &1.handle),
          "team_run_id" => team_run_id
        },
        acting_user_id: requester_user_id
      )
    end

    :ok
  end

  def note_bridge_team_user_turn(_chat_id, _workers, _text, _requester, _team_run_id), do: :ok

  @doc "Record a worker's answer into the shared group memory (no-op in DMs)."
  def note_bridge_agent_turn(chat_id, worker, text, requester_user_id, opts \\ [])

  def note_bridge_agent_turn(chat_id, worker, text, requester_user_id, opts)
      when is_binary(chat_id) and is_map(worker) do
    if is_binary(text) and String.trim(text) != "" and group_chat?(chat_id) do
      message =
        %{
          "role" => "assistant",
          "content" => clean_for_memory(text),
          "agent" => worker.handle,
          "agent_name" => worker.label
        }
        |> maybe_put("team_run_id", normalize_string(Keyword.get(opts, :team_run_id)))
        |> maybe_put("task_id", normalize_string(Keyword.get(opts, :task_id)))
        |> maybe_put("team_role", normalize_string(Keyword.get(opts, :team_role)))
        |> maybe_put("team_status", normalize_string(Keyword.get(opts, :status)))

      case GroupAgentMemory.append_message(chat_id, message, acting_user_id: requester_user_id) do
        {:ok, _memory} ->
          :ok

        error ->
          Logger.warning(
            "[LocalAgentWorker] worker memory append failed chat=#{chat_id} " <>
              "worker=#{worker.handle} reason=#{inspect(error)}"
          )
      end
    end

    :ok
  end

  def note_bridge_agent_turn(_chat_id, _worker, _text, _requester, _opts), do: :ok

  defp maybe_dispatch_next_team_worker(chat_id, worker, requester_user_id, opts) do
    team_run_id = normalize_string(Keyword.get(opts, :team_run_id))

    team_mode =
      normalize_string(Keyword.get(opts, :team_mode)) || team_run_mode(chat_id, team_run_id)

    cond do
      is_nil(team_run_id) ->
        :ok

      team_mode in ["supervisor", "group_supervisor"] ->
        if supervisor_lead?(chat_id, team_run_id, worker.handle) do
          clear_bridge_team_run(chat_id, team_run_id)
        else
          :ok
        end

      is_nil(requester_user_id) ->
        clear_bridge_team_run(chat_id, team_run_id)

      true ->
        dispatch_next_team_worker(chat_id, team_run_id, worker, requester_user_id)
    end
  end

  defp team_run_mode(chat_id, team_run_id) when is_binary(chat_id) and is_binary(team_run_id) do
    ensure_team_run_table()

    case :ets.lookup(@team_run_table, {chat_id, team_run_id}) do
      [{{^chat_id, ^team_run_id}, state}] ->
        Map.get(state, :mode)

      _ ->
        case Repo.get(TeamRun, team_run_id) do
          %TeamRun{mode: mode} -> mode
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  defp team_run_mode(_, _), do: nil

  defp supervisor_lead?(chat_id, team_run_id, handle)
       when is_binary(chat_id) and is_binary(team_run_id) and is_binary(handle) do
    ensure_team_run_table()

    case :ets.lookup(@team_run_table, {chat_id, team_run_id}) do
      [{{^chat_id, ^team_run_id}, state}] ->
        Map.get(state, :lead_worker) == handle

      _ ->
        case Repo.get(TeamRun, team_run_id) do
          %TeamRun{lead_worker: lead} -> lead == handle
          _ -> false
        end
    end
  rescue
    _ -> false
  end

  defp supervisor_lead?(_, _, _), do: false

  defp dispatch_next_team_worker(chat_id, team_run_id, completed_worker, requester_user_id) do
    ensure_team_run_table()

    case advance_durable_team_run(chat_id, team_run_id, completed_worker.handle) do
      {:next, state, next_handle} ->
        :ets.insert(@team_run_table, {{chat_id, team_run_id}, state})
        dispatch_team_worker_from_state(state, next_handle, completed_worker, requester_user_id)

      :done ->
        :ets.delete(@team_run_table, {chat_id, team_run_id})
        :ok

      :noop ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[LocalAgentWorker] durable team advance failed; using ETS fallback chat=#{chat_id} run=#{team_run_id} reason=#{inspect(reason)}"
        )

        dispatch_next_team_worker_from_cache(
          chat_id,
          team_run_id,
          completed_worker,
          requester_user_id
        )
    end
  end

  defp dispatch_next_team_worker_from_cache(
         chat_id,
         team_run_id,
         completed_worker,
         requester_user_id
       ) do
    case :ets.lookup(@team_run_table, {chat_id, team_run_id}) do
      [{{^chat_id, ^team_run_id}, state}] ->
        remaining = Map.get(state, :remaining, [])

        case remaining do
          [] ->
            clear_bridge_team_run(chat_id, team_run_id)

          [next_handle | rest] ->
            :ets.insert(@team_run_table, {{chat_id, team_run_id}, %{state | remaining: rest}})

            dispatch_team_worker_from_state(
              state,
              next_handle,
              completed_worker,
              requester_user_id
            )
        end

      _ ->
        :ok
    end
  end

  defp dispatch_team_worker_from_state(state, next_handle, completed_worker, requester_user_id) do
    case resolve_handle(next_handle) do
      nil ->
        clear_bridge_team_run(state.chat_id, state.team_run_id)

      next_worker ->
        team_workers =
          state.workers
          |> Enum.map(&resolve_handle/1)
          |> Enum.reject(&is_nil/1)

        bridge_prompt =
          build_team_bridge_prompt(
            state.chat_id,
            next_worker,
            state.dispatch_text,
            requester_user_id,
            team_workers,
            state.team_run_id
          )

        broadcast_activity(
          state.chat_id,
          next_worker.agent_user_id,
          "#{next_worker.label} continuing team run after #{completed_worker.label}...",
          "running"
        )

        task_payload =
          %{
            "provider" => next_worker.handle,
            "chatId" => state.chat_id,
            "taskId" => "#{state.team_run_id}-#{next_worker.handle}",
            "prompt" => bridge_prompt,
            "replyToId" => state.reply_to_id,
            "requesterUserId" => requester_user_id,
            "teamMode" => "group_team",
            "teamRunId" => state.team_run_id,
            "teamWorker" => next_worker.handle,
            "teamWorkers" => Enum.map(team_workers, & &1.handle)
          }
          |> Map.merge(resolve_provider_model(state.bridge_metadata || %{}, next_worker.handle))

        case AgentBridge.dispatch_task(requester_user_id, task_payload) do
          :ok ->
            Logger.info(
              "[LocalAgentWorker] chained team dispatch chat=#{state.chat_id} run=#{state.team_run_id} from=#{completed_worker.handle} to=#{next_worker.handle}"
            )

          {:error, reason} ->
            stop_activity(state.chat_id, next_worker.agent_user_id)

            notice =
              case reason do
                :computer_required ->
                  "Choose which connected computer should continue this team run."

                :computer_offline ->
                  "The selected computer went offline before @#{next_worker.handle} could continue the team run."

                _ ->
                  "Your computer went offline before @#{next_worker.handle} could continue the team run."
              end

            post_notice(
              next_worker,
              state.chat_id,
              notice,
              requester_user_id,
              state.reply_to_id
            )

            fail_bridge_team_run(
              state.chat_id,
              state.team_run_id,
              next_worker.handle,
              "Could not dispatch @#{next_worker.handle}: #{inspect(reason)}"
            )
        end
    end
  end

  defp group_chat?(chat_id) do
    case Chat.get_room_type(chat_id) do
      "dm" -> false
      nil -> false
      _ -> true
    end
  end

  defp group_framing(worker) do
    "You are #{worker.label}, collaborating with other AI agents (#{other_agents_label(worker)}) " <>
      "and people in a shared Vibe group chat. Everyone shares this conversation. When you finish, " <>
      "your reply is posted back into the group so the others can continue from it."
  end

  defp agent_operating_rules(worker, handoff_path \\ nil) do
    provider_file =
      case worker.handle do
        "claude" -> "CLAUDE.md"
        "codex" -> "CODEX.md"
        "grok" -> "AGENTS.md"
        "agy" -> "AGENTS.md"
        _ -> nil
      end

    provider_line =
      if provider_file do
        "- If the selected repo has #{provider_file} or .vibe/instructions/#{provider_file}, read it after AGENTS.md and follow it."
      end

    handoff_line =
      if is_binary(handoff_path) and handoff_path != "" do
        "- When repo writes are allowed, use #{handoff_path} as the shared handoff file. Keep edits additive under a \"#{worker.label}\" section: ownership, findings, files changed, blockers, and next steps."
      else
        "- If working with another agent, read teammate notes before continuing and avoid duplicate work."
      end

    [
      "Operating rules:",
      "- Act like a senior engineer in a production codebase.",
      "- Inspect existing code before editing and follow local patterns.",
      "- Keep changes scoped to the user's request; do not do unrelated refactors.",
      "- If the selected repo has AGENTS.md or .vibe/instructions/AGENTS.md, read it before editing and follow it.",
      provider_line,
      "- Start with read-only inspection when risk is unclear.",
      "- Do not delete files, reset git state, force push, rotate secrets, or run destructive commands unless the user explicitly approves.",
      "- Surface commands, files touched, patches, blockers, verification, and remaining risk clearly for Vibe's mobile UI.",
      "- If a command needs approval, explain the exact command, why it is needed, and the risk.",
      "- If the user assigns work by name, follow that assignment exactly.",
      "- If work is not assigned, choose a non-overlapping slice that fits your strengths and say what you took.",
      handoff_line,
      "- If a teammate is offline, unavailable, or rate-limited, say that clearly and continue with useful work that will not conflict.",
      "- Final replies should include what you completed, what was tested, what remains, and any handoff needed by the other teammate.",
      "- For GitHub PR review/comment when platforms are connected, prefer local `gh` / git with the user's machine credentials, or the Vibe platform API (`POST /api/platforms/tools/invoke`) — never invent tokens."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp platform_connectors_guidance(requester_user_id, worker)
       when is_binary(requester_user_id) and is_map(worker) do
    handle = worker[:handle] || worker["handle"] || "claude"

    case Vibe.Platforms.prompt_guidance(requester_user_id, "bridge_agent", to_string(handle)) do
      guidance when is_binary(guidance) and guidance != "" ->
        """
        Connected platform context (OAuth tokens stay on the Vibe server — never ask the user to paste secrets):
        #{String.trim(guidance)}
        Local coding agents may also use `gh` when the machine is already authenticated to GitHub.
        """
        |> String.trim()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp platform_connectors_guidance(_, _), do: nil

  defp other_agents_label(worker) do
    list_workers()
    |> Enum.reject(&(&1.handle == worker.handle))
    |> Enum.map_join(", ", & &1.label)
    |> case do
      "" -> "other agents"
      names -> names
    end
  end

  defp group_collaboration_context(chat_id, requester_user_id) do
    case GroupAgentMemory.get_or_create(chat_id, acting_user_id: requester_user_id) do
      {:ok, memory} ->
        summary_part =
          case memory.summary do
            s when is_binary(s) and s != "" -> "Summary of earlier discussion: #{s}\n"
            _ -> ""
          end

        lines =
          memory.messages
          |> List.wrap()
          |> Enum.take(-@group_context_messages)
          |> Enum.map(&format_thread_line/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        (summary_part <> lines) |> String.trim()

      _ ->
        ""
    end
  end

  defp format_thread_line(%{"role" => "assistant"} = msg) do
    name = msg["agent_name"] || "Agent"

    case truncate_line(msg["content"]) do
      "" -> nil
      content -> "#{name}: #{content}"
    end
  end

  defp format_thread_line(%{"role" => "user"} = msg) do
    who = msg["sender_name"] || "A teammate"

    label =
      cond do
        msg["target_agent"] == "team" ->
          "#{who} -> Team"

        is_binary(msg["target_agent"]) and msg["target_agent"] != "" ->
          "#{who} -> #{String.capitalize(msg["target_agent"])}"

        true ->
          who
      end

    label =
      case msg["team_run_id"] do
        run_id when is_binary(run_id) and run_id != "" -> "#{label} (team #{run_id})"
        _ -> label
      end

    case truncate_line(msg["content"]) do
      "" -> nil
      content -> "#{label}: #{content}"
    end
  end

  defp format_thread_line(_), do: nil

  defp truncate_line(nil), do: ""

  defp truncate_line(text) when is_binary(text) do
    collapsed = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(collapsed) > 500,
      do: String.slice(collapsed, 0, 497) <> "...",
      else: collapsed
  end

  defp truncate_line(_), do: ""

  defp clean_for_memory(text) when is_binary(text) do
    text
    |> String.replace(~r/(^|\s)@(claude|codex|grok|agy|antigravity|team)\b/iu, "\\1")
    |> String.replace(~r/(^|\s)\/team\b/iu, "\\1")
    |> String.replace(~r/^\s*team\s*:\s*/iu, "")
    |> String.trim()
  end

  defp clean_for_memory(_), do: ""

  defp team_workers_label(workers) do
    workers
    |> List.wrap()
    |> Enum.map(& &1.label)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> case do
      [] -> "Claude, Codex, Grok"
      names -> Enum.join(names, ", ")
    end
  end

  defp team_workers_handles(workers) do
    workers
    |> List.wrap()
    |> Enum.map(&"@#{&1.handle}")
    |> Enum.reject(&(&1 == "@"))
    |> case do
      [] -> "@claude, @codex, @grok, @agy"
      handles -> Enum.join(handles, ", ")
    end
  end

  defp team_worker_default_focus("codex"),
    do:
      "lead coordination, architecture, shared-file integration, backend/data implementation, and verification"

  defp team_worker_default_focus("claude"),
    do:
      "complete implementation of assigned backend/frontend slices, then review, debugging, and risk notes"

  defp team_worker_default_focus("grok"),
    do:
      "complete implementation of assigned slices, plus fast investigation and independent checks"

  defp team_worker_default_focus("agy"),
    do:
      "exact implementation of the assigned UI components/pages — follow the assigned file list precisely and completely"

  defp team_worker_default_focus(_), do: "the highest-value unowned slice"

  defp context_or_empty(""), do: "No previous shared group memory yet."
  defp context_or_empty(nil), do: "No previous shared group memory yet."
  defp context_or_empty(context), do: context

  defp safe_team_run_id(nil), do: "current"

  defp safe_team_run_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "current"
      safe -> String.slice(safe, 0, 80)
    end
  end

  defp sender_display_name(user_id) when is_binary(user_id) do
    case Vibe.Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> "A teammate"
    end
  rescue
    _ -> "A teammate"
  end

  defp sender_display_name(_), do: "A teammate"

  defp ensure_team_run_table do
    case :ets.whereis(@team_run_table) do
      :undefined ->
        :ets.new(@team_run_table, [:set, :public, :named_table, {:read_concurrency, true}])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end


  @doc "Broadcast a typing/agent-progress event into a chat for an agent."
  def broadcast_activity(chat_id, agent_user_id, label, status, tool \\ nil) do
    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "typing", %{
      "userId" => agent_user_id,
      "isAgent" => true
    })

    payload =
      %{"userId" => agent_user_id, "isAgent" => true, "label" => label, "status" => status}
      |> then(fn payload ->
        case tool do
          value when is_binary(value) and value != "" -> Map.put(payload, "tool", value)
          _ -> payload
        end
      end)

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-progress", payload)
  end

  @doc """
  Parse the bridge output accumulated so far and broadcast a live `agent-stream` update
  (partial text + inline progress/tool nodes) into the chat.
  """
  def bridge_stream_update(provider, chat_id, accumulated_output, stream_id) do
    bridge_stream_update(provider, chat_id, accumulated_output, stream_id, %{})
  end

  def bridge_stream_update(provider, chat_id, accumulated_output, stream_id, metadata)
      when is_binary(provider) and is_binary(chat_id) and is_binary(accumulated_output) do
    case resolve_handle(provider) do
      nil ->
        :ok

      worker ->
        extracted = extract_result(worker, accumulated_output)
        text = normalize_string(extracted.text) || ""
        session_id = session_id_from_output(accumulated_output)

        team_run_id = metadata["teamRunId"] || metadata[:team_run_id]
        team_mode = metadata["teamMode"] || metadata[:team_mode]

        suppress_visible? =
          truthy_opt?(metadata["suppressVisible"] || metadata[:suppress_visible])

        live_nodes =
          live_progress_nodes(worker, extracted)
          |> mark_latest_progress_node_running()

        last_label =
          live_nodes
          |> List.last()
          |> case do
            %{"label" => label} when is_binary(label) and label != "" -> label
            _ -> "working"
          end

        worker_status_list =
          if is_binary(team_run_id) do
            queued? = String.starts_with?(last_label, "Queued — waiting")

            progress_bytes =
              metadata["progressBytes"] || metadata[:progress_bytes] ||
                byte_size(accumulated_output)

            Vibe.AI.TeamRunMonitor.note_heartbeat(
              chat_id,
              team_run_id,
              worker.handle,
              queued?,
              progress_bytes
            )

            update_team_worker_state(chat_id, team_run_id, worker.handle, %{
              "status" => "running",
              "last_label" => String.slice(last_label, 0, 80),
              "task_id" => metadata["taskId"] || metadata[:task_id],
              "progress_bytes" => progress_bytes
            })
          else
            []
          end

        payload =
          %{
            "chatId" => chat_id,
            "streamId" => stream_id,
            "userId" => worker.agent_user_id,
            "agentUserId" => worker.agent_user_id,
            "agentName" => worker.label,
            "agentUsername" => worker.handle,
            "isAgent" => true,
            "isAgentMessage" => true,
            "text" => text,
            "progressNodes" => live_nodes,
            "toolEvents" => extracted.tool_events,
            "status" => "running"
          }
          |> maybe_put("taskId", metadata["taskId"] || metadata[:task_id])
          |> maybe_put("sessionId", session_id)
          |> maybe_put(
            "sourceMessageId",
            metadata["sourceMessageId"] || metadata[:source_message_id]
          )
          |> maybe_put("replyToId", metadata["replyToId"] || metadata[:reply_to_id])
          |> maybe_put("repoName", metadata["repoName"] || metadata[:repo_name])
          |> maybe_put("cwd", metadata["cwd"] || metadata[:cwd])
          |> maybe_put("workMode", metadata["workMode"] || metadata[:work_mode])
          |> maybe_put("model", metadata["model"] || metadata[:model])
          |> maybe_put("advisor", metadata["advisor"] || metadata[:advisor])
          |> maybe_put(
            "bridgeSentAtMs",
            metadata["bridgeSentAtMs"] || metadata["bridge_sent_at_ms"] ||
              metadata[:bridge_sent_at_ms]
          )
          |> maybe_put(
            "serverReceivedAtMs",
            metadata["serverReceivedAtMs"] || metadata["server_received_at_ms"] ||
              metadata[:server_received_at_ms]
          )
          |> maybe_put("serverBroadcastAtMs", System.system_time(:millisecond))
          |> maybe_put("sequence", metadata["sequence"] || metadata[:sequence])
          |> maybe_put("teamMode", team_mode)
          |> maybe_put("teamRunId", team_run_id)
          |> maybe_put("teamWorker", metadata["teamWorker"] || metadata[:team_worker])
          |> maybe_put(
            "teamWorkers",
            normalize_team_workers(metadata["teamWorkers"] || metadata[:team_workers])
          )
          |> maybe_put("leadWorker", metadata["leadWorker"] || metadata[:lead_worker])
          |> maybe_put("teamRole", metadata["teamRole"] || metadata[:team_role])
          |> maybe_put("suppressAllText", if(team_mode == "supervisor", do: true))
          |> maybe_put("suppressVisible", if(suppress_visible?, do: true))
          |> maybe_put("teamWorkersStatus", worker_status_list)
          |> maybe_put("computerId", metadata["computerId"] || metadata[:computer_id])
          |> maybe_put("computerLabel", metadata["computerLabel"] || metadata[:computer_label])

        VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-stream", payload)

        if suppress_visible? and is_binary(team_run_id) do
          VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-team-worker", %{
            "chatId" => chat_id,
            "teamRunId" => team_run_id,
            "teamMode" => team_mode || "supervisor",
            "teamWorker" => worker.handle,
            "leadWorker" => metadata["leadWorker"] || metadata[:lead_worker],
            "agentUserId" => worker.agent_user_id,
            "agentName" => worker.label,
            "status" => "running",
            "lastLabel" => last_label,
            "teamWorkersStatus" => worker_status_list,
            "suppressVisible" => true,
            "progressNodes" => live_nodes,
            "taskId" => metadata["taskId"] || metadata[:task_id]
          })
        end

        :ok
    end
  end

  def bridge_stream_update(_provider, _chat_id, _output, _stream_id, _metadata), do: :ok

  defp mark_latest_progress_node_running(nodes) when is_list(nodes) do
    {marked, _done} =
      nodes
      |> Enum.reverse()
      |> Enum.map_reduce(false, fn node, done ->
        cond do
          done ->
            {node, done}

          node["status"] in ["failed", "error", "cancelled", "canceled", "stopped"] ->
            {node, done}

          true ->
            {Map.put(node, "status", "running"), true}
        end
      end)

    Enum.reverse(marked)
  end

  defp mark_latest_progress_node_running(nodes), do: nodes

  defp live_progress_nodes(%{handle: "claude"}, extracted) do
    interleaved_claude_progress_nodes(extracted.decoded, extracted.tool_events, "")
    |> with_live_thinking(extracted.decoded)
  end

  defp live_progress_nodes(%{handle: "codex"}, extracted) do
    interleaved_codex_progress_nodes(extracted.decoded, extracted.tool_events, "")
  end

  defp live_progress_nodes(%{handle: "grok"}, extracted) do
    interleaved_grok_progress_nodes(extracted.decoded, extracted.tool_events, "")
    |> with_live_thinking(extracted.decoded)
  end

  defp live_progress_nodes(%{handle: "agy"}, extracted) do
    interleaved_grok_progress_nodes(extracted.decoded, extracted.tool_events, "")
    |> with_live_thinking(extracted.decoded)
    |> rewrite_progress_node_provider_prefix("grok", "agy")
  end

  defp live_progress_nodes(_worker, extracted), do: extracted.progress_nodes

  defp with_live_thinking(nodes, decoded) do
    case last_vibe_thinking(decoded) do
      nil ->
        nodes

      {tokens, active} ->
        status = if active, do: "streaming", else: "done"

        case last_thinking_index(nodes) do
          nil ->
            nodes ++
              [
                %{
                  "id" => "claude-thinking-live",
                  "label" => "Thinking",
                  "status" => status,
                  "kind" => "thinking",
                  "depth" => 0,
                  "tokens" => tokens
                }
              ]

          idx ->
            node =
              nodes
              |> Enum.at(idx)
              |> Map.put("tokens", tokens)
              |> Map.put("status", status)

            List.replace_at(nodes, idx, node)
        end
    end
  end

  defp last_vibe_thinking(decoded) do
    Enum.reduce(decoded, nil, fn ev, acc ->
      if is_map(ev) and ev["type"] == "vibe_thinking" do
        {normalize_runtime_int(ev["tokens"]) || 0, ev["active"] == true}
      else
        acc
      end
    end)
  end

  defp last_thinking_index(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {node, idx}, acc ->
      if is_map(node) and node["kind"] == "thinking", do: idx, else: acc
    end)
  end

  @doc "Mark a live stream finished. The final persisted message carries the content."
  def finish_stream(provider, chat_id, stream_id) do
    agent_id =
      case resolve_handle(provider) do
        nil -> agent_user_id()
        worker -> worker.agent_user_id
      end

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-stream", %{
      "chatId" => chat_id,
      "streamId" => stream_id,
      "userId" => agent_id,
      "isAgent" => true,
      "status" => "done"
    })
  end

  defp resolve_provider_model(bridge_metadata, provider) do
    {models, rest} = Map.pop(bridge_metadata, "models")
    {advisors, rest} = Map.pop(rest, "advisors")
    {efforts, rest} = Map.pop(rest, "efforts")
    provider_key = String.downcase(to_string(provider))

    rest =
      case is_map(models) && models[provider_key] do
        model when is_binary(model) and model != "" -> Map.put(rest, "model", model)
        _ -> rest
      end

    rest =
      case is_map(efforts) && efforts[provider_key] do
        effort when is_binary(effort) and effort != "" ->
          Map.put(rest, "reasoningEffort", effort)

        _ ->
          rest
      end

    case is_map(advisors) && advisors[provider_key] do
      advisor when is_binary(advisor) and advisor != "" -> Map.put(rest, "advisor", advisor)
      _ -> rest
    end
  end

  @doc "Broadcast that an agent has finished working in a chat."
  def stop_activity(chat_id, agent_user_id) do
    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-progress", %{
      "userId" => agent_user_id,
      "isAgent" => true,
      "status" => "done"
    })

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "stop-typing", %{
      "userId" => agent_user_id,
      "isAgent" => true
    })
  end

  defp do_run(worker, executable, prompt, opts) do
    run_cli(executor_for(worker), worker, executable, prompt, put_worker_model(worker, opts))
  end

  defp run_cli("codex", worker, executable, prompt, opts) do
    bridge_options = Keyword.get(opts, :bridge_metadata) || %{}

    sandbox =
      System.get_env("VIBE_CODEX_SANDBOX")
      |> normalize_string()
      |> case do
        value when value in ["read-only", "workspace-write", "danger-full-access"] -> value
        _ -> "read-only"
      end

    approval_policy =
      System.get_env("VIBE_CODEX_APPROVAL_POLICY")
      |> normalize_string()
      |> case do
        value when value in ["untrusted", "on-request", "never"] -> value
        _ -> "untrusted"
      end

    args =
      [
        "exec",
        "--json",
        "--sandbox",
        sandbox,
        "-c",
        "approval_policy=\"#{approval_policy}\"",
        "--cd",
        worker_cwd(worker),
        "--skip-git-repo-check",
        "--ephemeral"
      ] ++
        maybe_model_args(bridge_options, "VIBE_CODEX_MODEL", "--model") ++
        codex_reasoning_args(bridge_options) ++ [prompt]

    run_command(worker, executable, args, opts)
  end

  defp run_cli("claude", worker, executable, prompt, opts) do
    result = run_claude(worker, executable, prompt, opts)

    with {:ok, %{ok: false, text: text}} <- result,
         fallback when is_binary(fallback) <- claude_fallback_model(opts),
         true <- model_unavailable?(text) or usage_limit_text?(text) do
      Logger.warning(
        "[LocalAgentWorker] #{worker.handle} model unreachable — retrying on #{fallback}"
      )

      run_claude(worker, executable, prompt, use_fallback_model(opts, fallback))
    else
      _ -> result
    end
  end

  defp run_claude(worker, executable, prompt, opts) do
    bridge_options = Keyword.get(opts, :bridge_metadata) || %{}

    permission_mode =
      System.get_env("VIBE_CLAUDE_PERMISSION_MODE")
      |> normalize_string()
      |> case do
        value
        when value in ["default", "acceptEdits", "auto", "dontAsk", "bypassPermissions", "plan"] ->
          value

        _ ->
          "plan"
      end

    output_format =
      System.get_env("VIBE_CLAUDE_OUTPUT_FORMAT")
      |> normalize_string()
      |> case do
        value when value in ["json", "stream-json", "text"] -> value
        _ -> "stream-json"
      end

    args =
      [
        "-p",
        "--output-format",
        output_format,
        "--permission-mode",
        permission_mode
      ] ++
        claude_effort_args(bridge_options) ++
        claude_session_args(bridge_options) ++
        maybe_claude_verbose_args(output_format) ++
        maybe_model_args(bridge_options, "VIBE_CLAUDE_MODEL", "--model") ++
        maybe_advisor_args(bridge_options) ++
        maybe_single_arg("VIBE_CLAUDE_MCP_CONFIG", "--mcp-config") ++
        maybe_single_arg("VIBE_CLAUDE_ALLOWED_TOOLS", "--allowedTools") ++
        maybe_single_arg("VIBE_CLAUDE_DISALLOWED_TOOLS", "--disallowedTools") ++ ["--", prompt]

    run_command(worker, executable, args, opts)
  end

  defp run_cli("agy", worker, executable, prompt, opts) do
    bridge_options = Keyword.get(opts, :bridge_metadata) || %{}

    args =
      ["-p", prompt, "--print-timeout", System.get_env("VIBE_AGY_PRINT_TIMEOUT") || "30m"] ++
        agy_mode_args(bridge_options) ++
        agy_session_args(bridge_options) ++
        maybe_model_args(bridge_options, "VIBE_AGY_MODEL", "--model")

    run_command(worker, executable, args, opts)
  end

  defp agy_session_args(bridge_options) do
    case explicit_resume_session_id(bridge_options) do
      session_id when is_binary(session_id) -> ["--conversation", session_id]
      _ -> []
    end
  end

  defp agy_mode_args(bridge_options) do
    mode =
      bridge_options
      |> option_value("workMode")
      |> normalize_string()
      |> case do
        value when value in ["plan", "read_only"] -> "plan"
        value when value in ["full_access", "full", "danger"] -> "full"
        _ -> "accept"
      end

    case mode do
      "plan" -> ["--mode", "plan"]
      "full" -> ["--dangerously-skip-permissions"]
      _ -> ["--mode", "accept-edits", "--dangerously-skip-permissions"]
    end
  end

  defp run_cli("grok", worker, executable, prompt, opts) do
    bridge_options = Keyword.get(opts, :bridge_metadata) || %{}

    permission_mode =
      System.get_env("VIBE_GROK_PERMISSION_MODE")
      |> normalize_string()
      |> case do
        value
        when value in ["default", "acceptEdits", "auto", "dontAsk", "bypassPermissions", "plan"] ->
          value

        _ ->
          "default"
      end

    output_format =
      System.get_env("VIBE_GROK_OUTPUT_FORMAT")
      |> normalize_string()
      |> case do
        value when value in ["json", "streaming-json", "plain"] -> value
        _ -> "streaming-json"
      end

    args =
      [
        "-p",
        prompt,
        "--output-format",
        output_format,
        "--permission-mode",
        permission_mode
      ] ++
        grok_effort_args(bridge_options) ++
        grok_session_args(bridge_options) ++
        maybe_model_args(bridge_options, "VIBE_GROK_MODEL", "--model") ++
        maybe_grok_always_approve_args(permission_mode)

    run_command(worker, executable, args, opts)
  end

  defp claude_session_args(bridge_options) do
    case explicit_resume_session_id(bridge_options) do
      session_id when is_binary(session_id) -> ["--resume", session_id]
      _ -> []
    end
  end

  defp grok_session_args(bridge_options) do
    case explicit_resume_session_id(bridge_options) do
      session_id when is_binary(session_id) -> ["--resume", session_id]
      _ -> []
    end
  end

  defp grok_effort_args(options) do
    case normalize_reasoning_effort(option_value(options, "reasoningEffort"), :grok) do
      nil -> []
      effort -> ["--reasoning-effort", effort]
    end
  end

  defp maybe_grok_always_approve_args(mode) when mode in ["bypassPermissions", "auto"],
    do: ["--always-approve"]

  defp maybe_grok_always_approve_args(_), do: []

  defp run_command(worker, executable, args, opts) do
    start = System.monotonic_time(:millisecond)
    timeout_ms = timeout_ms(worker)
    progress_callback = Keyword.get(opts, :progress_callback, fn _event -> :ok end)

    Logger.info(
      "[LocalAgentWorker] start provider=#{worker.handle} command=#{Path.basename(executable)} timeout_ms=#{timeout_ms}"
    )

    line_callback = fn line ->
      line
      |> progress_event_from_line(worker)
      |> case do
        nil -> :ok
        event -> progress_callback.(event)
      end
    end

    case collect_command(executable, args, worker_cwd(worker), timeout_ms, line_callback) do
      {:ok, status, output} ->
        duration_ms = System.monotonic_time(:millisecond) - start
        extracted = extract_result(worker, output)
        text = extracted.text || fallback_output(output)
        ok = status == 0

        bridge_options = Keyword.get(opts, :bridge_metadata) || %{}

        if ok && explicit_resume_session_id(bridge_options) do
          store_session(
            Keyword.get(opts, :chat_id),
            worker.handle,
            session_id_from_output(output)
          )
        end

        Logger.info(
          "[LocalAgentWorker] finish provider=#{worker.handle} status=#{status} duration_ms=#{duration_ms} text_len=#{String.length(text)}"
        )

        {:ok,
         %{
           ok: ok,
           exit_status: status,
           command: Path.basename(executable),
           duration_ms: duration_ms,
           text: if(ok, do: text, else: command_failed_text(worker, status, text)),
           tool_events: extracted.tool_events,
           available_tools: extracted.available_tools,
           raw_event_count: extracted.raw_event_count,
           progress_nodes: extracted.progress_nodes
         }}

      {:error, :timeout, output} ->
        partial = extract_result(worker, output).text || ""
        {:error, {:timeout, timeout_ms, partial}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_command(executable, args, cwd, timeout_ms, line_callback) do
    shell = System.find_executable("sh") || "/bin/sh"
    shell_command = "exec </dev/null\nexec " <> shell_join([executable | args])

    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, ["-lc", shell_command]},
        {:cd, cwd}
      ])

    collect_port(port, [], "", line_callback, System.monotonic_time(:millisecond) + timeout_ms)
  rescue
    error -> {:error, error}
  end

  defp collect_port(port, chunks, line_buffer, line_callback, deadline_ms) do
    remaining = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        {lines, next_line_buffer} = split_complete_lines(line_buffer <> data)
        Enum.each(lines, &safe_line_callback(line_callback, &1))
        collect_port(port, [data | chunks], next_line_buffer, line_callback, deadline_ms)

      {^port, {:exit_status, status}} ->
        if normalize_string(line_buffer), do: safe_line_callback(line_callback, line_buffer)
        {:ok, status, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    after
      remaining ->
        Port.close(port)
        {:error, :timeout, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp post_worker_message(worker, chat_id, body, metadata, reply_to_id, requester_user_id) do
    agent_user_id = worker.agent_user_id

    with :ok <- ensure_agent_user_record(worker) do
      message_id = Ecto.UUID.generate()
      timestamp = System.system_time(:millisecond)
      plain_text = normalize_string(body) || ""

      metadata =
        metadata
        |> Map.put("isAgentMessage", true)
        |> Map.put("agentName", worker.label)
        |> Map.put("agentUserId", agent_user_id)
        |> Map.put("agentUsername", worker.handle)
        |> Map.put("agentHandle", "@#{worker.handle}")

      attrs = %{
        id: message_id,
        chat_id: chat_id,
        from_id: agent_user_id,
        encrypted_content: AgentMessageCrypto.encrypt_for_storage(plain_text),
        type: "text",
        metadata: metadata,
        reply_to_id: reply_to_id,
        timestamp: timestamp
      }

      case Chat.add_message(attrs, acting_user_id: requester_user_id || @agent_user_id) do
        {:ok, _message} ->
          payload = %{
            "id" => message_id,
            "fromId" => agent_user_id,
            "chatId" => chat_id,
            "encryptedContent" => "",
            "plainContent" => plain_text,
            "plaintext" => plain_text,
            "type" => "text",
            "timestamp" => timestamp,
            "status" => "sent",
            "isAgentMessage" => true,
            "agentName" => worker.label,
            "agentUserId" => agent_user_id,
            "agentUsername" => worker.handle,
            "agentHandle" => "@#{worker.handle}",
            "metadata" => metadata,
            "replyToId" => reply_to_id
          }

          VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message", payload)

          notify_chat_participants(
            chat_id,
            agent_user_id,
            message_id,
            timestamp,
            plain_text,
            payload
          )

          {:ok, %{message_id: message_id, timestamp: timestamp}}

        error ->
          error
      end
    end
  end

  defp duplicate_bridge_delivery?(chat_id, provider, reply_to_id, body) do
    ensure_deliver_dedupe_table()
    body_fp = delivery_body_fingerprint(body)
    key = {chat_id, provider, reply_to_id || "", body_fp}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@deliver_dedupe_table, key) do
      [{^key, at}] when now - at < @deliver_dedupe_ttl_ms ->
        true

      _ ->
        :ets.insert(@deliver_dedupe_table, {key, now})
        if :ets.info(@deliver_dedupe_table, :size) > 512 do
          prune_deliver_dedupe(now)
        end

        false
    end
  rescue
    _ -> false
  end

  defp delivery_body_fingerprint(body) when is_binary(body) do
    normalized =
      body
      |> String.trim()
      |> String.replace(~r/\s+/, " ")
      |> String.slice(0, 400)

    :crypto.hash(:sha256, normalized) |> Base.encode16(case: :lower)
  end

  defp delivery_body_fingerprint(_), do: "empty"

  defp ensure_deliver_dedupe_table do
    case :ets.whereis(@deliver_dedupe_table) do
      :undefined ->
        :ets.new(@deliver_dedupe_table, [
          :set,
          :public,
          :named_table,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp prune_deliver_dedupe(now) do
    cutoff = now - @deliver_dedupe_ttl_ms

    :ets.select_delete(@deliver_dedupe_table, [
      {
        {:"$1", :"$2"},
        [{:<, :"$2", cutoff}],
        [true]
      }
    ])
  rescue
    _ -> :ok
  end

  defp notify_chat_participants(
         chat_id,
         agent_user_id,
         message_id,
         timestamp,
         body,
         message_payload
       ) do
    mirrored_message = Chat.mirrored_message_payload(message_payload)

    Chat.get_all_participant_settings(chat_id)
    |> Enum.each(fn participant ->
      if participant.user_id != agent_user_id do
        if participant.deleted, do: Chat.restore_if_deleted(chat_id, participant.user_id)

        VibeWeb.Endpoint.broadcast!("user:#{participant.user_id}", "new_message", %{
          chat_id: chat_id,
          from_id: agent_user_id,
          message_id: message_id,
          timestamp: timestamp,
          muted: participant.muted || false,
          message: mirrored_message
        })

        if not participant.muted do
          _ =
            Notifications.send_message_push(participant.user_id, %{
              "chat_id" => chat_id,
              "message_id" => message_id,
              "from_id" => agent_user_id,
              "type" => "text",
              "body" => body
            })
        end
      end
    end)
  end

  defp ensure_agent_user_record(worker) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    agent_user_id = Ecto.UUID.dump!(worker.agent_user_id)

    Repo.insert_all(
      "users",
      [
        %{
          id: agent_user_id,
          username: worker.username,
          name: worker.name,
          password_hash: "agent",
          public_key: "agent",
          device_id: "agent",
          profile_image: worker.avatar_url,
          is_agent: true,
          tier: worker.tier,
          inserted_at: now,
          updated_at: now
        }
      ],
      conflict_target: [:id],
      on_conflict: [
        set: [
          updated_at: now,
          username: worker.username,
          name: worker.name,
          profile_image: worker.avatar_url,
          is_agent: true,
          tier: worker.tier
        ]
      ]
    )

    ensure_agent_gold_badge(worker)

    :ok
  rescue
    error -> {:error, error}
  end

  defp ensure_agent_gold_badge(worker) do
    case Badges.award_badge(worker.agent_user_id, "gold", "system") do
      {:ok, _badge} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "[LocalAgentWorker] failed to seed gold badge for #{worker.handle}: #{inspect(changeset.errors)}"
        )
    end
  end

  defp normalize_prompt(worker, prompt) do
    handle = Map.get(worker, :handle) || ""

    cleaned =
      prompt
      |> to_string()
      |> String.replace(~r/(?:^|\s)@(codex|claude|grok)\b/i, " ")
      |> String.replace(~r/(?:^|\s)@#{Regex.escape(handle)}\b/i, " ")
      |> String.trim()

    cond do
      cleaned == "" -> {:error, :missing_prompt}
      String.length(cleaned) > @max_prompt_length -> {:error, :prompt_too_long}
      true -> {:ok, prepend_role_prompt(worker, cleaned)}
    end
  end

  # A role worker leads with its standing brief; teammates are addressed by @handle.
  defp prepend_role_prompt(worker, prompt) do
    case normalize_string(Map.get(worker, :role_prompt)) do
      nil -> prompt
      role -> Enum.join([String.trim(@team_chat_rules), String.trim(role), prompt], "\n\n")
    end
  end

  defp command_for(worker) do
    if server_runtime?(worker) do
      executor = executor_for(worker)

      System.get_env(team_command_env(executor))
      |> normalize_string()
      |> Kernel.||(executor)
    else
      System.get_env(worker.command_env)
      |> normalize_string()
      |> Kernel.||(worker.default_command)
    end
  end

  # The team runs on its own compute, so its CLIs are configured separately from
  # the bridge's — point these at a wrapper to run them in another container.
  defp team_command_env("codex"), do: "VIBE_TEAM_CODEX_COMMAND"
  defp team_command_env("grok"), do: "VIBE_TEAM_GROK_COMMAND"
  defp team_command_env(_executor), do: "VIBE_TEAM_CLAUDE_COMMAND"

  defp worker_cwd(worker) do
    env = if server_runtime?(worker), do: "VIBE_TEAM_WORKSPACE", else: "VIBE_AGENT_WORKER_CWD"

    case normalize_string(System.get_env(env)) do
      nil -> default_workspace_dir()
      path -> if File.dir?(path), do: path, else: default_workspace_dir()
    end
  end

  defp default_workspace_dir do
    dir = Path.join(System.tmp_dir!() || "/tmp", "vibe-agent-workspace")
    File.mkdir_p(dir)
    dir
  end

  # Triage answers in seconds; patching a repo does not, so the team gets its own budget.
  defp timeout_ms(worker) do
    {env, fallback} =
      if server_runtime?(worker),
        do: {"VIBE_TEAM_TIMEOUT_MS", @default_team_timeout_ms},
        else: {"VIBE_AGENT_WORKER_TIMEOUT_MS", @default_timeout_ms}

    case Integer.parse(System.get_env(env) || "") do
      {value, _} when value >= 5_000 and value <= 900_000 -> value
      _ -> fallback
    end
  end

  defp claude_fallback_model(opts) do
    (Keyword.get(opts, :bridge_metadata) || %{})
    |> option_value("fallbackModel")
    |> normalize_string()
  end

  defp use_fallback_model(opts, fallback) do
    metadata =
      (Keyword.get(opts, :bridge_metadata) || %{})
      |> Map.drop(["fallbackModel", :fallbackModel])
      |> Map.put("model", fallback)

    Keyword.put(opts, :bridge_metadata, metadata)
  end

  # A plan without the model, an exhausted quota and a bad alias all mean the same thing here.
  defp model_unavailable?(text) when is_binary(text) do
    downcased = String.downcase(text)

    Enum.any?(
      [
        "not_found_error",
        "invalid model",
        "unknown model",
        "model not found",
        "does not have access",
        "not available",
        "rate_limit",
        "429",
        "insufficient credit",
        "credit balance"
      ],
      &String.contains?(downcased, &1)
    )
  end

  defp model_unavailable?(_), do: false

  defp maybe_model_args(options, env_name, flag) do
    case normalize_string(option_value(options, "model")) ||
           normalize_string(System.get_env(env_name)) do
      nil -> []
      model -> [flag, compatible_model(env_name, model)]
    end
  end

  defp compatible_model("VIBE_CODEX_MODEL", model) do
    case String.downcase(model) |> String.replace("_", "-") do
      value when value in ["gpt-5.6-sol", "gpt-5-6-sol", "gpt-5.6", "gpt-5-6"] -> "gpt-5.5"
      _ -> model
    end
  end

  defp compatible_model(_env_name, model), do: model

  defp maybe_advisor_args(options) do
    case normalize_string(option_value(options, "advisor")) ||
           normalize_string(System.get_env("VIBE_CLAUDE_ADVISOR")) ||
           normalize_string(System.get_env("VIBE_CLAUDE_ADVISOR_MODEL")) do
      nil -> []
      advisor -> ["--advisor", advisor]
    end
  end

  defp claude_effort_args(options) do
    case normalize_reasoning_effort(option_value(options, "reasoningEffort"), :claude) do
      nil -> []
      effort -> ["--effort", effort]
    end
  end

  defp codex_reasoning_args(options) do
    case normalize_reasoning_effort(option_value(options, "reasoningEffort"), :codex) do
      nil -> []
      effort -> ["-c", "model_reasoning_effort=\"#{effort}\""]
    end
  end

  defp normalize_reasoning_effort(value, provider) do
    value =
      value
      |> normalize_string()
      |> case do
        nil -> nil
        raw -> raw |> String.downcase() |> String.replace(["-", " "], "_")
      end

    case {provider, value} do
      {_, nil} -> nil
      {:claude, value} when value in ["low", "medium", "high", "xhigh", "max"] -> value
      {:claude, "extra_high"} -> "xhigh"
      {:claude, "ultrathink"} -> "max"
      {:codex, value} when value in ["low", "medium", "high"] -> value
      {:codex, value} when value in ["xhigh", "extra_high", "max", "ultrathink"] -> "high"
      {:grok, value} when value in ["low", "medium", "high"] -> value
      {:grok, value} when value in ["xhigh", "extra_high", "max", "ultrathink"] -> "high"
      _ -> nil
    end
  end

  defp option_value(options, key) when is_map(options) do
    options[key] || options[camelize_key(key)] || options[String.to_atom(key)]
  end

  defp option_value(_options, _key), do: nil

  defp explicit_resume_session_id(options) do
    [
      "agentBridgeResumeSessionId",
      "resumeSessionId",
      "resume_session_id",
      "sessionId",
      "session_id"
    ]
    |> Enum.find_value(fn key -> normalize_string(option_value(options, key)) end)
  end

  defp camelize_key("reasoningEffort"), do: "agentBridgeReasoningEffort"
  defp camelize_key("model"), do: "agentBridgeModel"
  defp camelize_key("advisor"), do: "agentBridgeAdvisor"
  defp camelize_key("resumeSessionId"), do: "agentBridgeResumeSessionId"
  defp camelize_key("sessionId"), do: "agentBridgeSessionId"
  defp camelize_key(key), do: key

  defp maybe_single_arg(env_name, flag) do
    case normalize_string(System.get_env(env_name)) do
      nil -> []
      value -> [flag, value]
    end
  end

  defp maybe_claude_verbose_args("stream-json"), do: ["--verbose"]
  defp maybe_claude_verbose_args(_), do: []

  defp extract_result(worker, output) do
    worker = parser_worker(worker)
    decoded = decoded_events(output)
    tool_events = tool_events_from_decoded(worker, decoded)
    text = extract_worker_text(worker, decoded, output)

    %{
      text: text,
      decoded: decoded,
      tool_events: tool_events,
      available_tools: available_tools_from_decoded(worker, decoded),
      raw_event_count: length(decoded),
      progress_nodes: build_progress_nodes(worker, decoded, tool_events, text)
    }
  end

  defp build_progress_nodes(%{handle: "claude"}, decoded, tool_events, summary_text) do
    interleaved_claude_progress_nodes(decoded, tool_events, summary_text)
  end

  defp build_progress_nodes(%{handle: "codex"}, decoded, tool_events, summary_text) do
    interleaved_codex_progress_nodes(decoded, tool_events, summary_text)
    |> Enum.take(@max_tool_events)
  end

  defp build_progress_nodes(%{handle: "grok"}, decoded, tool_events, summary_text) do
    interleaved_grok_progress_nodes(decoded, tool_events, summary_text)
  end

  defp build_progress_nodes(%{handle: "agy"}, decoded, tool_events, summary_text) do
    interleaved_grok_progress_nodes(decoded, tool_events, summary_text)
    |> rewrite_progress_node_provider_prefix("grok", "agy")
  end

  defp build_progress_nodes(_worker, _decoded, tool_events, _summary_text) do
    progress_nodes_from_events(tool_events)
  end

  defp rewrite_progress_node_provider_prefix(nodes, from, to) when is_list(nodes) do
    Enum.map(nodes, fn
      %{"id" => id} = node when is_binary(id) ->
        Map.put(node, "id", String.replace_prefix(id, from <> "-", to <> "-"))

      other ->
        other
    end)
  end

  defp rewrite_progress_node_provider_prefix(nodes, _from, _to), do: nodes

  defp interleaved_grok_progress_nodes(decoded, tool_events, summary_text) do
    summary_norm = summary_text |> to_string() |> String.trim()
    tool_by_id = Map.new(tool_events || [], fn ev -> {ev["id"], ev} end)

    settled =
      Enum.any?(decoded, fn
        %{"type" => "end"} -> true
        _ -> false
      end)

    think_status = if settled, do: "done", else: "streaming"
    text_status = if settled, do: "done", else: "streaming"

    initial = %{
      nodes: [],
      thought: "",
      answer: "",
      used_tools: MapSet.new(),
      thought_flushed: false,
      seg: 0,
      need_new_seg: false
    }

    state =
      Enum.reduce(decoded, initial, fn event, st ->
        cond do
          not is_map(event) ->
            st

          event["type"] == "thought" and is_binary(event["data"]) ->
            st
            |> grok_begin_thought_phase()
            |> Map.update!(:thought, &(&1 <> event["data"]))
            |> Map.put(:thought_flushed, false)

          event["type"] == "text" and is_binary(event["data"]) ->
            st
            |> grok_flush_thought_node(think_status)
            |> grok_begin_text_phase()
            |> Map.update!(:answer, &join_grok_text_chunks([&1, event["data"]]))

          event["type"] == "tool_use" ->
            id = normalize_string(event["id"]) || unique_event_id("grok-tool", length(st.nodes))

            st
            |> grok_flush_thought_node(think_status)
            |> grok_flush_answer_node(summary_norm, text_status)
            |> grok_put_tool_node(id, event, tool_by_id)

          event["type"] == "tool_result" ->
            id = normalize_string(event["tool_use_id"] || event["id"])
            grok_mark_tool_result(st, id, event)

          event["type"] in ["compacting", "auto_compact_started"] ->
            grok_put_compacting_node(st, "running", event)

          event["type"] in ["compacted", "auto_compact_completed"] ->
            grok_put_compacting_node(st, "done", event)

          is_binary(event["thought"]) and event["type"] not in ["text", "end"] ->
            st
            |> grok_begin_thought_phase()
            |> Map.update!(:thought, &(&1 <> event["thought"]))
            |> Map.put(:thought_flushed, false)

          is_binary(event["text"]) and
              event["type"] not in ["thought", "end", "tool_use", "tool_result"] ->
            st
            |> grok_flush_thought_node(think_status)
            |> grok_begin_text_phase()
            |> Map.update!(:answer, &join_grok_text_chunks([&1, event["text"]]))

          true ->
            blocks = content_blocks_from_event(event)

            Enum.reduce(blocks, st, fn block, inner ->
              case block do
                %{"type" => "tool_use"} = tool_block ->
                  id =
                    normalize_string(tool_block["id"]) ||
                      unique_event_id("grok-tool", length(inner.nodes))

                  inner
                  |> grok_flush_thought_node(think_status)
                  |> grok_flush_answer_node(summary_norm, text_status)
                  |> grok_put_tool_node(id, tool_block, tool_by_id)

                %{"type" => "tool_result"} = result_block ->
                  id = normalize_string(result_block["tool_use_id"] || result_block["id"])
                  grok_mark_tool_result(inner, id, result_block)

                %{"type" => "thinking", "thinking" => body} when is_binary(body) ->
                  inner
                  |> grok_begin_thought_phase()
                  |> Map.update!(:thought, &(&1 <> body))
                  |> Map.put(:thought_flushed, false)

                %{"type" => "text", "text" => body} when is_binary(body) ->
                  inner
                  |> grok_flush_thought_node(think_status)
                  |> grok_begin_text_phase()
                  |> Map.update!(:answer, &join_grok_text_chunks([&1, body]))

                _ ->
                  inner
              end
            end)
        end
      end)

    state
    |> grok_flush_thought_node(think_status)
    |> grok_flush_answer_node(summary_norm, text_status)
    |> Map.get(:nodes)
  end

  defp grok_begin_thought_phase(st) do
    st =
      if String.trim(st.answer) != "" do
        st
        |> grok_flush_answer_node("", "done")
        |> Map.put(:answer, "")
        |> Map.put(:need_new_seg, true)
      else
        st
      end

    if st.need_new_seg or (st.thought_flushed and String.trim(st.thought) == "") do
      %{st | seg: st.seg + 1, need_new_seg: false, thought_flushed: false}
    else
      st
    end
  end

  defp grok_begin_text_phase(st) do
    if st.need_new_seg do
      %{st | seg: st.seg + 1, need_new_seg: false}
    else
      st
    end
  end

  defp grok_flush_thought_node(st, status) do
    body = String.trim(st.thought)

    cond do
      body == "" and not st.thought_flushed ->
        st

      body == "" ->
        st

      true ->
        tokens = max(1, div(String.length(body), 4))
        seg = st.seg

        node = %{
          "id" => "grok-thinking-#{seg}",
          "label" => "Thinking",
          "status" => status,
          "kind" => "thinking",
          "depth" => 0,
          "tokens" => tokens,
          "detail" => clip_text_node(body),
          "output" => clip_text_node(body)
        }

        nodes = upsert_progress_node(st.nodes, node)
        %{st | nodes: nodes, thought_flushed: true}
    end
  end

  defp grok_flush_answer_node(st, summary_norm, status) do
    body = String.trim(st.answer)

    cond do
      body == "" ->
        st

      body == summary_norm and summary_norm != "" ->
        st

      true ->
        seg = st.seg

        node = %{
          "id" => "grok-text-#{seg}",
          "label" => clip_text_node(body),
          "status" => status,
          "kind" => "text",
          "depth" => 0,
          "detail" => clip_text_node(body)
        }

        %{st | nodes: upsert_progress_node(st.nodes, node)}
    end
  end

  defp grok_put_tool_node(st, id, tool_block, tool_by_id) do
    if MapSet.member?(st.used_tools, id) do
      st
    else
      event =
        Map.get(tool_by_id, id) ||
          %{
            "id" => id,
            "tool" => normalize_string(tool_block["name"]) || "tool",
            "label" =>
              tool_label(
                "Grok",
                normalize_string(tool_block["name"]) || "tool",
                tool_block["input"] || %{}
              ),
            "status" => "running",
            "input" => safe_payload(tool_block["input"] || %{}),
            "providerEventType" => "tool_use"
          }
          |> put_node_shape(
            normalize_string(tool_block["name"]) || "tool",
            tool_block["input"] || %{}
          )

      node = tool_event_to_node(event, length(st.nodes))
      %{
        st
        | nodes: st.nodes ++ [node],
          used_tools: MapSet.put(st.used_tools, id),
          need_new_seg: true,
          thought: "",
          answer: "",
          thought_flushed: false
      }
    end
  end

  defp grok_put_compacting_node(st, status, event) when is_map(event) do
    id = normalize_string(event["id"]) || "grok-compacting-#{st.seg}"
    tokens_before = event["tokens_before"] || event["tokensBefore"]
    tokens_after = event["tokens_after"] || event["tokensAfter"]

    label =
      cond do
        status == "done" and is_integer(tokens_before) and is_integer(tokens_after) ->
          "Compacted context · #{tokens_before} → #{tokens_after} tokens"

        status == "done" ->
          "Compacted conversation"

        true ->
          "Compacting conversation…"
      end

    node = %{
      "id" => id,
      "label" => label,
      "status" => status,
      "kind" => "compacting",
      "depth" => 0
    }

    nodes = upsert_progress_node(st.nodes, node)

    %{
      st
      | nodes: nodes,
        need_new_seg: true,
        thought: "",
        answer: "",
        thought_flushed: false
    }
  end

  defp grok_put_compacting_node(st, _status, _event), do: st

  defp grok_mark_tool_result(st, nil, _event), do: st

  defp grok_mark_tool_result(st, id, event) do
    failed =
      event["is_error"] == true || event["isError"] == true ||
        to_string(event["status"] || "") in ["error", "failed", "cancelled"]

    status = if failed, do: "error", else: "done"

    nodes =
      Enum.map(st.nodes, fn node ->
        if to_string(node["id"] || "") == id do
          Map.put(node, "status", status)
        else
          node
        end
      end)

    %{st | nodes: nodes}
  end

  defp upsert_progress_node(nodes, node) when is_list(nodes) and is_map(node) do
    id = to_string(node["id"] || "")

    case Enum.find_index(nodes, fn n -> to_string(n["id"] || "") == id end) do
      nil ->
        nodes ++ [node]

      idx ->
        List.replace_at(nodes, idx, node)
    end
  end

  defp upsert_progress_node(nodes, _node), do: nodes

  defp interleaved_codex_progress_nodes(decoded, tool_events, summary_text) do
    summary_norm = summary_text |> to_string() |> String.trim()

    {nodes, used, _text_index, _thinking_count} =
      decoded
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new(), 0, 0}, fn {event, index},
                                                  {nodes, used, text_index, thinking_count} ->
        item = codex_event_item(event)

        cond do
          is_map(item) ->
            type = codex_item_type(item) || ""

            cond do
              type == "reasoning" ->
                if thinking_count >= 4 do
                  {nodes, used, text_index, thinking_count}
                else
                  node = %{
                    "id" => "codex-thinking-#{index}",
                    "label" => "Thinking",
                    "status" => "done",
                    "depth" => 0,
                    "kind" => "thinking"
                  }

                  {[node | nodes], used, text_index, thinking_count + 1}
                end

              codex_agent_message?(item) ->
                text = codex_item_text(item)
                trimmed = text |> to_string() |> String.trim()

                if trimmed == "" or trimmed == summary_norm do
                  {nodes, used, text_index, thinking_count}
                else
                  node = %{
                    "id" => "codex-text-#{text_index}",
                    "label" => clip_text_node(text),
                    "status" => "done",
                    "depth" => 0,
                    "kind" => "text"
                  }

                  {[node | nodes], used, text_index + 1, thinking_count}
                end

              type in ["agent_message", "message"] ->
                {nodes, used, text_index, thinking_count}

              true ->
                id = codex_tool_event_id(event, item, index)
                matching =
                  tool_events
                  |> Enum.filter(fn tool_event ->
                    tool_id = to_string(tool_event["id"] || "")
                    tool_id == id or String.starts_with?(tool_id, id <> ":")
                  end)

                Enum.reduce(matching, {nodes, used, text_index, thinking_count}, fn
                  tool_event, {inner_nodes, inner_used, inner_text_index, inner_thinking_count} ->
                    tool_id = tool_event["id"]

                    if MapSet.member?(inner_used, tool_id) do
                      {inner_nodes, inner_used, inner_text_index, inner_thinking_count}
                    else
                      node = tool_event_to_node(tool_event, length(inner_nodes))

                      {
                        [node | inner_nodes],
                        MapSet.put(inner_used, tool_id),
                        inner_text_index,
                        inner_thinking_count
                      }
                    end
                end)
            end

          true ->
            {nodes, used, text_index, thinking_count}
        end
      end)

    remaining_tool_nodes =
      tool_events
      |> Enum.reject(fn event -> MapSet.member?(used, event["id"]) end)
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> tool_event_to_node(event, index) end)

    Enum.reverse(nodes) ++ remaining_tool_nodes
  end

  defp interleaved_claude_progress_nodes(decoded, tool_events, summary_text) do
    tool_by_id = Map.new(tool_events, fn ev -> {ev["id"], ev} end)
    summary_norm = summary_text |> to_string() |> String.trim()

    compact_nodes =
      decoded
      |> Enum.reduce([], fn event, acc ->
        cond do
          not is_map(event) ->
            acc

          event["type"] in ["auto_compact_started", "compacting"] ->
            [
              %{
                "id" => normalize_string(event["id"]) || "claude-compacting",
                "label" => "Compacting conversation…",
                "status" => "running",
                "kind" => "compacting",
                "depth" => 0
              }
              | acc
            ]

          event["type"] in ["auto_compact_completed", "compacted"] ->
            [
              %{
                "id" => normalize_string(event["id"]) || "claude-compacting",
                "label" => "Compacted conversation",
                "status" => "done",
                "kind" => "compacting",
                "depth" => 0
              }
              | acc
            ]

          true ->
            acc
        end
      end)
      |> Enum.reverse()

    {nodes, _used, _text_index} =
      decoded
      |> Enum.flat_map(fn event ->
        parent = normalize_string(event["parent_tool_use_id"])
        event |> content_blocks_from_event() |> Enum.map(fn block -> {block, parent} end)
      end)
      |> Enum.reduce({[], MapSet.new(), 0}, fn {block, parent}, {nodes, used, ti} ->
        case block do
          %{"type" => "text", "text" => raw_text} when is_binary(raw_text) ->
            trimmed = String.trim(raw_text)

            if trimmed == "" or trimmed == summary_norm do
              {nodes, used, ti}
            else
              node =
                %{
                  "id" => "worker-text-#{ti}",
                  "label" => clip_text_node(raw_text),
                  "status" => "done",
                  "depth" => 0,
                  "kind" => "text"
                }
                |> put_subagent_depth(parent)

              {[node | nodes], used, ti + 1}
            end

          %{"type" => "tool_use"} = tool_block ->
            id = normalize_string(tool_block["id"])

            case id && Map.get(tool_by_id, id) do
              nil ->
                {nodes, used, ti}

              event ->
                if MapSet.member?(used, id) do
                  {nodes, used, ti}
                else
                  {[tool_event_to_node(event, length(nodes)) | nodes], MapSet.put(used, id), ti}
                end
            end

          _ ->
            if block["type"] == "thinking" do
              node =
                %{
                  "id" => "claude-thinking-#{ti}",
                  "label" => "Thinking",
                  "status" => "done",
                  "depth" => 0,
                  "kind" => "thinking"
                }
                |> put_subagent_depth(parent)

              {[node | nodes], used, ti + 1}
            else
              {nodes, used, ti}
            end
        end
      end)

    compact_nodes ++ Enum.reverse(nodes)
  end

  defp clip_text_node(text) do
    text = String.trim(to_string(text))

    if String.length(text) > 4000 do
      String.slice(text, 0, 4000) <> "…"
    else
      text
    end
  end

  defp tool_event_to_node(event, index) do
    node =
      %{
        "id" => event["id"] || unique_event_id("worker-progress", index),
        "label" => event["label"] || event["tool"] || "Working...",
        "status" => event["status"] || "running",
        "depth" => 0
      }
      |> copy_node_shape(event)

    case Map.get(event, "outputPreview") || Map.get(event, "output") do
      preview when is_binary(preview) and preview != "" ->
        node
        |> Map.put("detail", clip_text_node(preview))
        |> Map.put("output", clip_text_node(preview))

      _ ->
        node
    end
  end

  defp extract_worker_text(%{handle: "codex"}, decoded, output) do
    extract_codex_text(decoded) || plain_output_text(decoded, output)
  end

  defp extract_worker_text(%{handle: "claude"}, decoded, output) do
    extract_claude_text(decoded) || plain_output_text(decoded, output)
  end

  defp extract_worker_text(%{handle: "grok"}, decoded, output) do
    extract_grok_text(decoded) || plain_output_text(decoded, output)
  end

  defp extract_worker_text(%{handle: "agy"}, decoded, output) do
    extract_grok_text(decoded) || plain_output_text(decoded, output)
  end

  defp extract_worker_text(_worker, decoded, output), do: plain_output_text(decoded, output)

  defp extract_grok_text(decoded) do
    streaming =
      decoded
      |> Enum.filter(fn
        %{"type" => "text", "data" => data} when is_binary(data) -> true
        _ -> false
      end)
      |> Enum.map(& &1["data"])
      |> join_grok_text_chunks()
      |> normalize_string()

    streaming ||
      decoded
      |> Enum.reduce(nil, fn event, acc ->
        cond do
          not is_map(event) ->
            acc

          is_binary(event["text"]) and event["type"] not in ["thought", "end"] ->
            event["text"]

          is_binary(event["result"]) ->
            event["result"]

          true ->
            acc
        end
      end)
      |> normalize_string()
  end

  defp join_grok_text_chunks([]), do: ""

  defp join_grok_text_chunks(chunks) when is_list(chunks) do
    chunks
    |> Enum.map(&to_string/1)
    |> Enum.join("")
  end

  defp plain_output_text([], output), do: normalize_string(output)
  defp plain_output_text(_decoded, _output), do: nil

  defp decoded_events(output) do
    line_events =
      output
      |> to_string()
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, event} when is_map(event) -> [event]
          {:ok, events} when is_list(events) -> Enum.filter(events, &is_map/1)
          _ -> []
        end
      end)

    if line_events != [] do
      line_events
    else
      case Jason.decode(output) do
        {:ok, event} when is_map(event) -> [event]
        {:ok, events} when is_list(events) -> Enum.filter(events, &is_map/1)
        _ -> []
      end
    end
  end

  defp extract_codex_text(decoded) do
    decoded
    |> Enum.reduce(nil, fn event, acc ->
      item = codex_event_item(event) || event

      cond do
        codex_agent_message?(item) ->
          codex_item_text(item) || acc

        codex_envelope_error_message(event) != nil ->
          codex_envelope_error_message(event)

        true ->
          acc
      end
    end)
    |> normalize_string()
  end

  defp codex_envelope_error_message(event) when is_map(event) do
    type = normalize_string(event["type"]) || ""

    cond do
      type in ["error", "turn.failed", "thread.failed"] ->
        normalize_string(event["message"]) ||
          normalize_string(get_in(event, ["error", "message"]))

      true ->
        nil
    end
  end

  defp codex_envelope_error_message(_), do: nil

  defp extract_claude_text(decoded) do
    result_text =
      decoded
      |> Enum.reduce(nil, fn event, acc ->
        cond do
          is_binary(event["result"]) ->
            event["result"]

          is_binary(event["content"]) ->
            event["content"]

          is_map(event["message"]) ->
            content_blocks_text(event["message"]["content"]) || acc

          true ->
            acc
        end
      end)
      |> normalize_string()

    result_text ||
      decoded
      |> Enum.flat_map(fn event ->
        event
        |> content_blocks_from_event()
        |> Enum.filter(&match?(%{"type" => "text"}, &1))
        |> Enum.map(&(&1["text"] || ""))
      end)
      |> Enum.join("\n")
      |> normalize_string()
  end

  defp tool_events_from_decoded(%{handle: "claude"}, decoded) do
    decoded
    |> claude_tool_events()
    |> Enum.take(@max_tool_events)
  end

  defp tool_events_from_decoded(%{handle: "codex"}, decoded) do
    decoded
    |> codex_tool_events()
    |> Enum.take(@max_tool_events)
  end

  defp tool_events_from_decoded(%{handle: "grok"}, decoded) do
    decoded
    |> grok_tool_events()
    |> Enum.take(@max_tool_events)
  end

  defp tool_events_from_decoded(%{handle: "agy"}, decoded) do
    decoded
    |> grok_tool_events()
    |> Enum.map(fn ev ->
      ev
      |> Map.put("provider", "agy")
      |> Map.update("label", nil, fn
        label when is_binary(label) -> String.replace(label, "Grok", "Agy")
        other -> other
      end)
    end)
    |> Enum.take(@max_tool_events)
  end

  defp tool_events_from_decoded(_worker, _decoded), do: []

  defp grok_tool_events(decoded) do
    {events_by_id, order} =
      Enum.reduce(decoded, {%{}, []}, fn event, {events_by_id, order} = acc ->
        cond do
          not is_map(event) ->
            acc

          event["type"] == "tool_use" ->
            id = normalize_string(event["id"]) || unique_event_id("grok-tool", length(order))
            tool = normalize_string(event["name"]) || "tool"
            input = event["input"] || %{}

            ev =
              %{
                "id" => id,
                "provider" => "grok",
                "tool" => tool,
                "label" => tool_label("Grok", tool, input),
                "status" => "running",
                "input" => safe_payload(input),
                "providerEventType" => "tool_use"
              }
              |> put_node_shape(tool, input)

            {Map.put(events_by_id, id, ev), append_once(order, id)}

          event["type"] == "tool_result" ->
            id = normalize_string(event["tool_use_id"] || event["id"])

            if id && Map.has_key?(events_by_id, id) do
              failed =
                event["is_error"] == true || event["isError"] == true ||
                  to_string(event["status"] || "") in ["error", "failed", "cancelled"]

              prev = Map.fetch!(events_by_id, id)

              updated =
                prev
                |> Map.put("status", if(failed, do: "error", else: "done"))
                |> Map.put(
                  "output",
                  event["content"] || event["output"] || prev["output"]
                )

              {Map.put(events_by_id, id, updated), order}
            else
              acc
            end

          true ->
            event
            |> content_blocks_from_event()
            |> Enum.reduce(acc, fn block, inner ->
              accumulate_claude_tool_block(block, nil, inner)
            end)
        end
      end)

    order
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(events_by_id, &1))
  end

  defp claude_tool_events(decoded) do
    {events_by_id, order} =
      Enum.reduce(decoded, {%{}, []}, fn event, acc ->
        parent = normalize_string(event["parent_tool_use_id"])

        event
        |> content_blocks_from_event()
        |> Enum.reduce(acc, fn block, inner ->
          accumulate_claude_tool_block(block, parent, inner)
        end)
      end)

    order
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(events_by_id, &1))
  end

  defp accumulate_claude_tool_block(
         %{"type" => "tool_use"} = block,
         parent,
         {events_by_id, order}
       ) do
    id = normalize_string(block["id"]) || unique_event_id("claude-tool", length(order))
    tool = normalize_string(block["name"]) || "tool"
    input = block["input"] || %{}

    event =
      %{
        "id" => id,
        "provider" => "claude",
        "tool" => tool,
        "label" => tool_label("Claude", tool, input),
        "status" => "running",
        "input" => safe_payload(input),
        "providerEventType" => "tool_use"
      }
      |> put_node_shape(tool, input)
      |> put_subagent_shape(parent)

    {Map.put(events_by_id, id, event), append_once(order, id)}
  end

  defp accumulate_claude_tool_block(
         %{"type" => "tool_result"} = block,
         parent,
         {events_by_id, order}
       ) do
    id =
      normalize_string(block["tool_use_id"]) ||
        normalize_string(block["id"]) ||
        unique_event_id("claude-result", length(order))

    existing = Map.get(events_by_id, id)
    tool = (existing && existing["tool"]) || "tool_result"
    output = block["content"] || block["text"] || block["result"]
    status = if block["is_error"] == true, do: "failed", else: "done"

    event =
      (existing ||
         %{
           "id" => id,
           "provider" => "claude",
           "tool" => tool,
           "label" => tool_label("Claude", tool, %{}),
           "input" => %{}
         }
         |> put_subagent_shape(parent))
      |> Map.merge(%{
        "status" => status,
        "outputPreview" => safe_text(output),
        "providerEventType" => "tool_result"
      })

    {Map.put(events_by_id, id, event), append_once(order, id)}
  end

  defp accumulate_claude_tool_block(_block, _parent, acc), do: acc

  defp put_subagent_shape(event, parent) when is_binary(parent) and parent != "" do
    event |> Map.put("depth", 1) |> Map.put("parentId", parent)
  end

  defp put_subagent_shape(event, _parent), do: Map.put_new(event, "depth", 0)

  defp put_subagent_depth(node, parent) when is_binary(parent) and parent != "" do
    node |> Map.put("depth", 1) |> Map.put("parentId", parent)
  end

  defp put_subagent_depth(node, _parent), do: node

  defp codex_tool_events(decoded) do
    ignored_call_ids =
      decoded
      |> Enum.map(&codex_event_item/1)
      |> Enum.filter(&codex_ignored_action_item?/1)
      |> Enum.map(&normalize_string(&1["call_id"]))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    decoded
    |> Enum.with_index()
    |> Enum.flat_map(fn {event, index} ->
      item = codex_event_item(event)

      cond do
        is_map(item) ->
          type = codex_item_type(item) || ""

          cond do
            type in ["agent_message", "reasoning", "message"] ->
              []

            type in ["function_call_output", "custom_tool_call_output"] and
                MapSet.member?(ignored_call_ids, normalize_string(item["call_id"])) ->
              []

            true ->
              case codex_tool_event(event, item, type, index) do
                nil -> []
                tool_events when is_list(tool_events) -> tool_events
                tool_event -> [tool_event]
              end
          end

        codex_envelope_error_message(event) != nil ->
          [codex_error_tool_event(event, index)]

        true ->
          []
      end
    end)
    |> compact_tool_events()
  end

  defp codex_event_item(event) when is_map(event) do
    cond do
      is_map(map_value(event, "item")) ->
        map_value(event, "item")

      normalize_string(event["type"]) == "response_item" and is_map(event["payload"]) ->
        event["payload"]

      normalize_string(event["type"]) != "event_msg" and is_map(event["payload"]) and
          codex_known_item_type?(event["payload"]) ->
        event["payload"]

      true ->
        nil
    end
  end

  defp codex_event_item(_), do: nil

  defp codex_item_type(item) when is_map(item) do
    normalize_string(item["item_type"]) || normalize_string(item["type"])
  end

  defp codex_item_type(_), do: nil

  defp codex_known_item_type?(item) when is_map(item) do
    (codex_item_type(item) || "") in [
      "agent_message",
      "message",
      "reasoning",
      "command_execution",
      "file_change",
      "web_search",
      "mcp_tool_call",
      "function_call",
      "function_call_output",
      "custom_tool_call",
      "custom_tool_call_output",
      "todo_list",
      "error"
    ]
  end

  defp codex_known_item_type?(_), do: false

  defp codex_agent_message?(item) when is_map(item) do
    case codex_item_type(item) do
      "agent_message" ->
        true

      "message" ->
        role = item["role"] |> normalize_string() |> then(&(&1 && String.downcase(&1)))
        role in ["assistant", "agent"]

      _ ->
        false
    end
  end

  defp codex_agent_message?(_), do: false

  defp codex_item_text(item) when is_map(item) do
    normalize_string(item["text"]) ||
      normalize_string(item["message"]) ||
      content_blocks_text(item["content"])
  end

  defp codex_item_text(_), do: nil

  defp codex_tool_event_id(event, item, index) do
    normalize_string(item["call_id"]) ||
      normalize_string(item["id"]) ||
      normalize_string(event["id"]) ||
      unique_event_id("codex-tool", index)
  end

  defp codex_tool_event(event, item, type, index) do
    case codex_item_fields(type, item) do
      :ignore ->
        nil

      {:many, fields} ->
        base_id = codex_tool_event_id(event, item, index)

        fields
        |> Enum.with_index()
        |> Enum.map(fn {{tool, input, output}, action_index} ->
          codex_tool_event_from_fields(
            event,
            item,
            type,
            "#{base_id}:#{action_index}",
            tool,
            input,
            output
          )
        end)

      {tool, input, output} ->
        codex_tool_event_from_fields(
          event,
          item,
          type,
          codex_tool_event_id(event, item, index),
          tool,
          input,
          output
        )
    end
  end

  defp codex_tool_event_from_fields(event, item, type, id, tool, input, output) do
    %{
      "id" => id,
      "provider" => "codex",
      "tool" => tool,
      "label" => tool_label("Codex", tool, input),
      "status" => codex_item_status(event, item),
      "input" => safe_payload(input),
      "outputPreview" => safe_text(output),
      "providerEventType" => normalize_string(event["type"]) || type
    }
    |> put_node_shape(tool, input)
    |> codex_apply_file_change_shape(type, item)
  end

  defp codex_error_tool_event(event, index) do
    message = codex_envelope_error_message(event)

    id =
      case message do
        text when is_binary(text) ->
          "codex-error-" <>
            (:crypto.hash(:md5, text) |> Base.encode16(case: :lower) |> binary_part(0, 8))

        _ ->
          unique_event_id("codex-error", index)
      end

    %{
      "id" => normalize_string(event["id"]) || id,
      "provider" => "codex",
      "tool" => "Error",
      "label" => "Codex error",
      "status" => "failed",
      "input" => %{},
      "outputPreview" => safe_text(message),
      "providerEventType" => normalize_string(event["type"]) || "error",
      "kind" => "error"
    }
  end

  defp codex_item_fields("command_execution", item) do
    command = codex_command_string(item)
    output = item["aggregated_output"] || item["stdout"] || item["output"]
    {tool, input} = codex_shell_tool(command)
    {tool, input, output}
  end

  defp codex_item_fields("file_change", item) do
    paths = codex_file_change_paths(item)
    input = %{"file_path" => List.first(paths)}
    input = if length(paths) > 1, do: Map.put(input, "files", paths), else: input
    {codex_file_change_tool(item), input, item["stdout"] || item["output"]}
  end

  defp codex_item_fields("web_search", item) do
    query = normalize_string(item["query"]) || normalize_string(item["action"])
    {"WebSearch", %{"query" => query}, nil}
  end

  defp codex_item_fields("mcp_tool_call", item) do
    tool = normalize_string(item["tool"]) || normalize_string(item["name"]) || "tool"
    server = normalize_string(item["server"]) || "mcp"
    label = "mcp__#{server}__#{tool}"

    input =
      cond do
        is_map(item["arguments"]) ->
          Map.merge(item["arguments"], %{"server" => server, "tool" => tool})

        is_binary(item["arguments"]) ->
          %{"arguments" => item["arguments"], "server" => server, "tool" => tool}

        true ->
          %{"server" => server, "tool" => tool}
      end

    {label, input, item["result"] || item["output"] || item["content"]}
  end

  defp codex_item_fields("function_call", item) do
    name = normalize_string(item["name"]) || normalize_string(item["tool"]) || "tool"
    codex_function_fields_from_raw(name, item["arguments"])
  end

  defp codex_item_fields("function_call_output", item) do
    output = item["output"] || item["result"] || item["content"]
    {"Tool result", %{}, output}
  end

  defp codex_item_fields("custom_tool_call", item) do
    name = normalize_string(item["name"]) || normalize_string(item["tool"]) || "tool"
    codex_function_fields_from_raw(name, item["input"] || item["arguments"])
  end

  defp codex_item_fields("custom_tool_call_output", item) do
    output = item["output"] || item["result"] || item["content"]
    {"Tool result", %{}, output}
  end

  defp codex_item_fields("todo_list", item) do
    {"TodoWrite", %{"todos" => item["items"] || item["todos"] || []}, nil}
  end

  defp codex_item_fields("error", item) do
    {"Error", %{}, item["message"] || item["text"]}
  end

  defp codex_item_fields(type, item) do
    output = item["output"] || item["result"] || item["content"] || item["text"]

    case codex_command_string(item) do
      nil ->
        tool =
          cond do
            normalize_string(item["name"]) -> normalize_string(item["name"])
            normalize_string(item["tool"]) -> normalize_string(item["tool"])
            type not in [nil, ""] -> codex_titlecase(type)
            true -> "Tool"
          end

        input =
          cond do
            is_map(item["input"]) -> item["input"]
            is_map(item["arguments"]) -> item["arguments"]
            is_binary(item["arguments"]) -> %{"arguments" => item["arguments"]}
            true -> %{}
          end

        {tool, input, output}

      command ->
        {tool, input} = codex_shell_tool(command)
        {tool, input, output}
    end
  end

  defp codex_function_fields(name, input) do
    input = codex_normalize_function_input(name, input)

    if codex_shell_tool_name?(name) do
      {tool, shell_input} = codex_shell_tool(codex_command_string(input))
      {tool, shell_input, nil}
    else
      {codex_function_tool_name(name, input), input, nil}
    end
  end

  defp codex_function_fields_from_raw(name, raw) do
    case codex_unwrap_function_payloads(name, raw) do
      [] ->
        :ignore

      [{inner_name, input}] ->
        codex_function_fields(inner_name, input)

      actions ->
        {:many,
         Enum.map(actions, fn {inner_name, input} ->
           codex_function_fields(inner_name, input)
         end)}
    end
  end

  defp codex_command_string(item) do
    cond do
      is_binary(item["command"]) ->
        normalize_string(item["command"])

      is_list(item["command"]) ->
        item["command"] |> Enum.join(" ") |> normalize_string()

      is_binary(item["cmd"]) ->
        normalize_string(item["cmd"])

      is_map(item["input"]) and is_binary(item["input"]["cmd"]) ->
        normalize_string(item["input"]["cmd"])

      is_map(item["input"]) and is_binary(item["input"]["command"]) ->
        normalize_string(item["input"]["command"])

      true ->
        nil
    end
  end

  @codex_read_cmds ~w(cat head tail less more bat nl sed)
  @codex_search_cmds ~w(rg grep egrep fgrep ag ack ripgrep)
  @codex_shell_tool_names ~w(exec exec_command shell local_shell container.exec bash run_command)
  @codex_exec_output_helpers ~w(text image generatedImage store load notify yield_control)
  @codex_continuation_tools ~w(wait write_stdin wait_agent list_agents)

  defp codex_shell_tool(command) do
    cmd = command |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
    bash = {"Bash", %{"command" => cmd}}

    if cmd == "" do
      bash
    else
      first =
        cmd
        |> codex_unwrap_shell()
        |> String.split(~r/\s*(?:&&|\|\||[|;])\s*/, parts: 2)
        |> List.first()
        |> to_string()

      case first |> codex_shell_tokens() |> codex_strip_shell_prefixes() do
        [] ->
          bash

        [prog | args] ->
          base = prog |> String.split("/") |> List.last() |> String.downcase()

          cond do
            base in @codex_read_cmds -> codex_shell_read_tool(base, args, bash)
            base in @codex_search_cmds -> codex_shell_search_tool(args, bash)
            true -> bash
          end
      end
    end
  end

  defp codex_shell_tool_name?(name), do: to_string(name) in @codex_shell_tool_names

  defp codex_shell_read_tool("sed", args, bash) do
    has_range = Enum.any?(args, &Regex.match?(~r/^\d+,\d+p?$/, &1))

    if "-n" in args or has_range do
      codex_shell_read_tool(nil, args, bash)
    else
      bash
    end
  end

  defp codex_shell_read_tool(_prog, args, bash) do
    case codex_last_path_arg(args) do
      nil -> bash
      file -> {"Read", %{"file_path" => file}}
    end
  end

  defp codex_shell_search_tool(args, bash) do
    case codex_search_pattern(args, false) do
      nil -> bash
      pattern -> {"Grep", %{"pattern" => pattern}}
    end
  end

  defp codex_unwrap_shell(cmd) do
    case Regex.run(~r/^(?:\/\S+\/)?(?:bash|sh|zsh)\s+-[a-z]*c\s+(.+)$/i, cmd) do
      [_, inner] -> inner |> String.trim() |> codex_unquote()
      _ -> cmd
    end
  end

  defp codex_unquote(s) do
    first = String.first(s)

    if first in ["\"", "'"] and String.last(s) == first and String.length(s) >= 2 do
      s |> String.slice(1, String.length(s) - 2) |> String.trim()
    else
      s
    end
  end

  defp codex_shell_tokens(command) do
    {toks, cur, started, _quote} =
      command
      |> to_string()
      |> String.graphemes()
      |> Enum.reduce({[], "", false, nil}, fn ch, {toks, cur, started, quote} ->
        cond do
          quote != nil ->
            if ch == quote, do: {toks, cur, true, nil}, else: {toks, cur <> ch, true, quote}

          ch == "\"" or ch == "'" ->
            {toks, cur, true, ch}

          ch == " " or ch == "\t" ->
            if started, do: {[cur | toks], "", false, nil}, else: {toks, cur, false, nil}

          true ->
            {toks, cur <> ch, true, nil}
        end
      end)

    toks = if started, do: [cur | toks], else: toks
    Enum.reverse(toks)
  end

  defp codex_strip_shell_prefixes([tok | rest] = tokens) do
    cond do
      Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, tok) -> codex_strip_shell_prefixes(rest)
      tok in ["sudo", "command"] -> codex_strip_shell_prefixes(rest)
      true -> tokens
    end
  end

  defp codex_strip_shell_prefixes([]), do: []

  defp codex_last_path_arg(args) do
    args
    |> Enum.reverse()
    |> Enum.find(fn a ->
      a != "" and not String.starts_with?(a, "-") and
        not Regex.match?(~r/^\d+(,\d+)?[a-z]?$/i, a)
    end)
  end

  defp codex_search_pattern([], _take_next), do: nil

  defp codex_search_pattern([a | rest], take_next) do
    cond do
      take_next -> a
      a in ["-e", "--regexp", "--regex"] -> codex_search_pattern(rest, true)
      a != "" and not String.starts_with?(a, "-") -> a
      true -> codex_search_pattern(rest, false)
    end
  end

  defp codex_decode_arguments(arguments) when is_map(arguments), do: arguments

  defp codex_decode_arguments(arguments) when is_binary(arguments) do
    cond do
      apply_patch_envelope?(arguments) ->
        codex_apply_patch_input(arguments)

      true ->
        case Jason.decode(arguments) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> %{"arguments" => arguments}
        end
    end
  end

  defp codex_decode_arguments(_), do: %{}

  defp codex_unwrap_function_payloads(name, raw) do
    cond do
      name in @codex_continuation_tools ->
        []

      name != "exec" or not is_binary(raw) ->
        [{name, codex_decode_arguments(raw)}]

      true ->
        actionable =
          raw
          |> codex_nested_tool_calls()
          |> Enum.reject(fn {nested, _segment} ->
            nested in @codex_exec_output_helpers or nested in @codex_continuation_tools
          end)

        cond do
          actionable == [] ->
            direct = codex_decode_arguments(raw)
            if codex_command_string(direct), do: [{name, direct}], else: []

          true ->
            Enum.map(actionable, fn {inner_name, segment} ->
              {inner_name, codex_nested_tool_input(inner_name, segment)}
            end)
        end
    end
  end

  defp codex_nested_tool_calls(source) do
    codex_scan_nested_tool_calls(source, 0, []) |> Enum.reverse()
  end

  defp codex_scan_nested_tool_calls(source, index, acc) when index >= byte_size(source),
    do: acc

  defp codex_scan_nested_tool_calls(source, index, acc) do
    byte = :binary.at(source, index)

    cond do
      byte in [?", ?', ?`] ->
        codex_scan_nested_tool_calls(source, codex_skip_js_string(source, index, byte), acc)

      codex_binary_starts_at?(source, index, "tools.") ->
        name_start = index + byte_size("tools.")
        name_end = codex_identifier_end(source, name_start)
        open_index = codex_skip_ascii_space(source, name_end)

        if name_end > name_start and open_index < byte_size(source) and
             :binary.at(source, open_index) == ?( do
          call_end = codex_balanced_call_end(source, open_index, 0)
          name = binary_part(source, name_start, name_end - name_start)
          segment = binary_part(source, index, max(0, call_end - index))
          codex_scan_nested_tool_calls(source, call_end, [{name, segment} | acc])
        else
          codex_scan_nested_tool_calls(source, index + 1, acc)
        end

      true ->
        codex_scan_nested_tool_calls(source, index + 1, acc)
    end
  end

  defp codex_skip_js_string(source, index, quote) do
    next = index + 1

    cond do
      next >= byte_size(source) ->
        byte_size(source)

      :binary.at(source, next) == ?\\ ->
        codex_skip_js_string(source, min(next + 1, byte_size(source) - 1), quote)

      :binary.at(source, next) == quote ->
        next + 1

      true ->
        codex_skip_js_string(source, next, quote)
    end
  end

  defp codex_identifier_end(source, index) when index >= byte_size(source), do: index

  defp codex_identifier_end(source, index) do
    byte = :binary.at(source, index)

    if (byte >= ?a and byte <= ?z) or (byte >= ?A and byte <= ?Z) or
         (byte >= ?0 and byte <= ?9) or byte == ?_ do
      codex_identifier_end(source, index + 1)
    else
      index
    end
  end

  defp codex_skip_ascii_space(source, index) when index >= byte_size(source), do: index

  defp codex_skip_ascii_space(source, index) do
    if :binary.at(source, index) in [32, 9, 10, 13],
      do: codex_skip_ascii_space(source, index + 1),
      else: index
  end

  defp codex_balanced_call_end(source, index, _depth) when index >= byte_size(source),
    do: byte_size(source)

  defp codex_balanced_call_end(source, index, depth) do
    byte = :binary.at(source, index)

    cond do
      byte in [?", ?', ?`] ->
        codex_balanced_call_end(source, codex_skip_js_string(source, index, byte), depth)

      byte == ?( ->
        codex_balanced_call_end(source, index + 1, depth + 1)

      byte == ?) and depth == 1 ->
        index + 1

      byte == ?) ->
        codex_balanced_call_end(source, index + 1, depth - 1)

      true ->
        codex_balanced_call_end(source, index + 1, depth)
    end
  end

  defp codex_binary_starts_at?(source, index, prefix) do
    length = byte_size(prefix)
    index + length <= byte_size(source) and binary_part(source, index, length) == prefix
  end

  defp codex_nested_tool_input("exec_command", source) do
    %{}
    |> maybe_put(
      "command",
      codex_js_property_string(source, "cmd") || codex_js_property_string(source, "command")
    )
    |> maybe_put("workdir", codex_js_property_string(source, "workdir"))
  end

  defp codex_nested_tool_input("apply_patch", source) do
    case codex_patch_text_from_source(source) do
      nil -> %{}
      patch -> codex_apply_patch_input(patch)
    end
  end

  defp codex_nested_tool_input("view_image", source) do
    %{} |> maybe_put("file_path", codex_js_property_string(source, "path"))
  end

  defp codex_nested_tool_input("web__run", source) do
    %{} |> maybe_put("query", codex_js_property_string(source, "q"))
  end

  defp codex_nested_tool_input("update_plan", source) do
    steps = codex_js_property_strings(source, "step")
    statuses = codex_js_property_strings(source, "status")

    todos =
      steps
      |> Enum.with_index()
      |> Enum.map(fn {step, index} ->
        %{
          "content" => step,
          "status" => Enum.at(statuses, index) || "pending",
          "activeForm" => ""
        }
      end)

    %{"todos" => todos}
  end

  # Nested MCP: tools.mcp__vibeask__ask_fable({ question: "…" })
  defp codex_nested_tool_input(name, source) when is_binary(name) do
    if String.starts_with?(name, "mcp__") or
         Regex.match?(~r/^[a-z][a-z0-9_-]*__[a-z0-9_-]+$/i, name) do
      %{}
      |> maybe_put("question", codex_js_property_string(source, "question"))
      |> maybe_put("query", codex_js_property_string(source, "query"))
      |> maybe_put("prompt", codex_js_property_string(source, "prompt"))
    else
      %{}
    end
  end

  defp codex_nested_tool_input(_name, _source), do: %{}

  defp codex_js_property_string(source, key) do
    escaped_key = Regex.escape(key)

    regex =
      Regex.compile!(
        "(?:\\b#{escaped_key}\\b|[\"']#{escaped_key}[\"'])\\s*:\\s*(\"(?:\\\\.|[^\"\\\\])*\")",
        "s"
      )

    case Regex.run(regex, source, capture: :all_but_first) do
      [literal] -> codex_decode_js_double_quoted(literal)
      _ -> nil
    end
  end

  defp codex_js_property_strings(source, key) do
    escaped_key = Regex.escape(key)

    Regex.compile!(
      "(?:\\b#{escaped_key}\\b|[\"']#{escaped_key}[\"'])\\s*:\\s*(\"(?:\\\\.|[^\"\\\\])*\")",
      "s"
    )
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(&List.first/1)
    |> Enum.map(&codex_decode_js_double_quoted/1)
    |> Enum.reject(&is_nil/1)
  end

  defp codex_patch_text_from_source(source) do
    trimmed = String.trim_leading(source)

    cond do
      String.starts_with?(trimmed, "*** Begin Patch") and
          String.contains?(source, "*** End Patch") ->
        source

      true ->
        ~r/"((?:\\.|[^"\\])*)"/s
        |> Regex.scan(source, capture: :all_but_first)
        |> Enum.find_value(fn [body] ->
          case codex_decode_js_double_quoted("\"" <> body <> "\"") do
            value when is_binary(value) ->
              if String.contains?(value, "*** Begin Patch") and
                   String.contains?(value, "*** End Patch"),
                 do: value

            _ ->
              nil
          end
        end)
    end
  end

  defp codex_decode_js_double_quoted(literal) do
    case Jason.decode(literal) do
      {:ok, value} when is_binary(value) -> value
      _ -> nil
    end
  end

  defp codex_ignored_action_item?(item) when is_map(item) do
    type = codex_item_type(item)

    if type in ["function_call", "custom_tool_call"] do
      codex_item_fields(type, item) == :ignore
    else
      false
    end
  end

  defp codex_ignored_action_item?(_), do: false

  defp codex_function_tool_name("exec_command", input) do
    if codex_command_string(%{"input" => input}), do: "Bash", else: "exec_command"
  end

  defp codex_function_tool_name("apply_patch", _input), do: "Edit"
  defp codex_function_tool_name("view_image", _input), do: "Read"
  defp codex_function_tool_name("update_plan", _input), do: "TodoWrite"

  defp codex_function_tool_name(name, _input)
       when name in ["spawn_agent", "spawn_subagent", "delegate_to_subagent"],
       do: "Task"

  defp codex_function_tool_name(name, _input)
       when name in ["send_message", "followup_task"],
       do: "Task"

  defp codex_function_tool_name("web__run", _input), do: "WebSearch"
  defp codex_function_tool_name(name, _input), do: name

  defp codex_normalize_function_input("update_plan", input) when is_map(input) do
    raw = input["todos"] || input["plan"] || input["items"] || []

    todos =
      if is_list(raw) do
        Enum.map(raw, fn item ->
          %{
            "content" => to_string(item["content"] || item["step"] || ""),
            "status" => to_string(item["status"] || "pending"),
            "activeForm" => to_string(item["activeForm"] || "")
          }
        end)
      else
        []
      end

    Map.put(input, "todos", todos)
  end

  defp codex_normalize_function_input(name, input)
       when name in ["spawn_agent", "spawn_subagent", "delegate_to_subagent"] and
              is_map(input) do
    task_name =
      input["task_name"] || input["name"] || input["subagent_type"] || "subagent"

    input
    |> Map.put("description", to_string(task_name))
    |> Map.put("subagent_type", to_string(task_name))
  end

  defp codex_normalize_function_input(name, input)
       when name in ["send_message", "followup_task"] and is_map(input) do
    target = input["target"] || input["task_name"] || "subagent"

    input
    |> Map.put(
      "description",
      "Message #{to_string(target) |> String.replace_prefix("/root/", "")}"
    )
    |> Map.put("subagent_type", to_string(target) |> String.replace_prefix("/root/", ""))
  end

  defp codex_normalize_function_input(_name, input), do: input

  defp apply_patch_envelope?(value) when is_binary(value) do
    String.contains?(value, "*** Begin Patch") and String.contains?(value, "*** End Patch")
  end

  defp apply_patch_envelope?(_), do: false

  defp codex_apply_patch_input(patch) when is_binary(patch) do
    files = apply_patch_files(patch)
    paths = files |> Enum.map(&normalize_string(&1["path"])) |> Enum.reject(&is_nil/1)

    %{"patch" => patch}
    |> maybe_put("file_path", List.first(paths))
    |> maybe_put("files", if(paths == [], do: nil, else: paths))
    |> maybe_put("patchFiles", if(files == [], do: nil, else: files))
  end

  defp apply_patch_files(patch) when is_binary(patch) do
    {files, current} =
      patch
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn line, {files, current} ->
        cond do
          path = apply_patch_header_path(line, "*** Add File: ") ->
            {finish_patch_file(files, current), new_patch_file(path, "add")}

          path = apply_patch_header_path(line, "*** Update File: ") ->
            {finish_patch_file(files, current), new_patch_file(path, "update")}

          path = apply_patch_header_path(line, "*** Delete File: ") ->
            {finish_patch_file(files, current), new_patch_file(path, "delete")}

          String.starts_with?(line, "*** End Patch") ->
            {finish_patch_file(files, current), nil}

          is_map(current) and String.starts_with?(line, "+") and
              not String.starts_with?(line, "+++") ->
            {files, Map.update!(current, "additions", &(&1 + 1))}

          is_map(current) and String.starts_with?(line, "-") and
              not String.starts_with?(line, "---") ->
            {files, Map.update!(current, "deletions", &(&1 + 1))}

          true ->
            {files, current}
        end
      end)

    files
    |> finish_patch_file(current)
    |> Enum.reverse()
  end

  defp apply_patch_files(_), do: []

  defp apply_patch_header_path(line, prefix) do
    if String.starts_with?(line, prefix) do
      line
      |> String.replace(prefix, "", global: false)
      |> normalize_string()
    end
  end

  defp new_patch_file(path, action) do
    %{
      "path" => path,
      "action" => action,
      "additions" => 0,
      "deletions" => 0
    }
  end

  defp finish_patch_file(files, %{"path" => path} = current) when is_binary(path) do
    [current | files]
  end

  defp finish_patch_file(files, _), do: files

  defp patch_files_from_input(input) when is_map(input) do
    cond do
      is_list(input["patchFiles"]) ->
        input["patchFiles"]
        |> Enum.map(&normalize_patch_file/1)
        |> Enum.reject(&is_nil/1)

      apply_patch_envelope?(input["patch"]) ->
        apply_patch_files(input["patch"])

      apply_patch_envelope?(input["arguments"]) ->
        apply_patch_files(input["arguments"])

      is_list(input["files"]) ->
        input["files"]
        |> Enum.map(&normalize_patch_file/1)
        |> Enum.reject(&is_nil/1)

      true ->
        []
    end
  end

  defp patch_files_from_input(_), do: []

  defp normalize_patch_file(%{"path" => path} = file) do
    case normalize_string(path) do
      nil ->
        nil

      normalized_path ->
        %{
          "path" => normalized_path,
          "action" => normalize_string(file["action"]),
          "additions" => normalize_runtime_int(file["additions"]) || 0,
          "deletions" => normalize_runtime_int(file["deletions"]) || 0
        }
    end
  end

  defp normalize_patch_file(path) when is_binary(path) do
    case normalize_string(path) do
      nil -> nil
      normalized_path -> %{"path" => normalized_path, "additions" => 0, "deletions" => 0}
    end
  end

  defp normalize_patch_file(_), do: nil

  defp first_patch_path(input) do
    input
    |> patch_files_from_input()
    |> Enum.find_value(&normalize_string(&1["path"]))
  end

  defp patch_target(input) do
    files = patch_files_from_input(input)

    case files do
      [] ->
        nil

      [file] ->
        file["path"] |> normalize_string() |> target_basename()

      files ->
        "#{length(files)} files"
    end
  end

  defp apply_patch_stats(input) when is_map(input) do
    files = patch_files_from_input(input)

    if files == [] do
      nil
    else
      Enum.reduce(files, {0, 0}, fn file, {added, removed} ->
        {added + (normalize_runtime_int(file["additions"]) || 0),
         removed + (normalize_runtime_int(file["deletions"]) || 0)}
      end)
    end
  end

  defp apply_patch_stats(_), do: nil

  defp codex_file_change_paths(item) do
    case item["changes"] do
      changes when is_list(changes) ->
        changes
        |> Enum.map(fn
          %{"path" => path} -> normalize_string(path)
          path when is_binary(path) -> normalize_string(path)
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        [normalize_string(item["path"]) || normalize_string(item["file_path"])]
        |> Enum.reject(&is_nil/1)
    end
  end

  defp codex_file_change_tool(item) do
    kinds =
      case item["changes"] do
        changes when is_list(changes) ->
          Enum.map(changes, fn
            %{"kind" => kind} -> normalize_string(kind)
            _ -> nil
          end)

        _ ->
          []
      end
      |> Enum.reject(&is_nil/1)

    cond do
      kinds != [] and Enum.all?(kinds, &(&1 == "add")) -> "Write"
      true -> "Edit"
    end
  end

  defp codex_apply_file_change_shape(event, "file_change", item) do
    paths = codex_file_change_paths(item)
    target = paths |> List.first() |> codex_basename()

    target =
      cond do
        length(paths) > 1 -> "#{length(paths)} files"
        true -> target
      end

    kind = if codex_file_change_tool(item) == "Write", do: "write", else: "edit"

    event
    |> Map.put("kind", kind)
    |> maybe_put("target", target)
  end

  defp codex_apply_file_change_shape(event, _type, _item), do: event

  defp codex_basename(nil), do: nil
  defp codex_basename(path) when is_binary(path), do: Path.basename(path)

  defp codex_titlecase(type) do
    type
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp codex_item_status(event, item) do
    envelope = (normalize_string(event["type"]) || "") |> String.downcase()
    item_type = (codex_item_type(item) || "") |> String.downcase()
    item_status = (normalize_string(item["status"]) || "") |> String.downcase()
    exit_code = item["exit_code"]

    cond do
      is_integer(exit_code) and exit_code != 0 ->
        "failed"

      String.contains?(item_status, ["fail", "error", "abort", "interrupt", "not_found"]) ->
        "failed"

      envelope in ["turn.failed", "error", "thread.failed"] ->
        "failed"

      item_type in ["function_call_output", "custom_tool_call_output"] ->
        "done"

      String.contains?(item_status, ["complete", "done", "success"]) ->
        "done"

      envelope in ["item.completed", "turn.completed"] ->
        "done"

      is_integer(exit_code) and exit_code == 0 ->
        "done"

      String.contains?(item_status, ["progress", "running", "start", "pending"]) ->
        "running"

      envelope in ["item.started", "item.updated"] ->
        "running"

      true ->
        "running"
    end
  end

  defp compact_tool_events(events) do
    {events_by_id, order} =
      Enum.reduce(events, {%{}, []}, fn event, {events_by_id, order} ->
        id = event["id"]
        merged = merge_tool_event(Map.get(events_by_id, id), event)

        {Map.put(events_by_id, id, merged), append_once(order, id)}
      end)

    order
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(events_by_id, &1))
  end

  defp merge_tool_event(nil, event), do: event

  defp merge_tool_event(existing, event) do
    Map.merge(existing, event, fn
      "tool", old, "Tool result" -> old
      "label", old, new -> if generic_tool_result_label?(new), do: old, else: new
      "input", old, new when is_map(new) and map_size(new) == 0 -> old
      "kind", old, "tool" -> old
      "kind", old, nil -> old
      "target", old, nil -> old
      _key, _old, new -> new
    end)
  end

  defp generic_tool_result_label?(value) when is_binary(value) do
    String.downcase(value) in ["tool result", "codex tool result"]
  end

  defp generic_tool_result_label?(_), do: false

  defp available_tools_from_decoded(%{handle: "claude"}, decoded) do
    decoded
    |> Enum.flat_map(fn
      %{"tools" => tools} when is_list(tools) -> tools
      %{"message" => %{"tools" => tools}} when is_list(tools) -> tools
      _ -> []
    end)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(40)
  end

  defp available_tools_from_decoded(_worker, _decoded), do: []

  defp progress_nodes_from_events(events) do
    events
    |> Enum.with_index()
    |> Enum.map(fn {event, index} -> tool_event_to_node(event, index) end)
  end

  defp progress_nodes_with_runtime(nodes, nil), do: nodes

  defp progress_nodes_with_runtime(nodes, runtime) when is_map(runtime) do
    runtime_nodes = runtime_progress_nodes(runtime)
    Enum.take(nodes ++ runtime_nodes, @max_tool_events + @max_runtime_files + 1)
  end

  defp runtime_progress_nodes(runtime) do
    diff = runtime["diff"] || %{}

    files =
      case diff["files"] do
        value when is_list(value) -> value
        _ -> []
      end

    task_id = runtime["taskId"] || "bridge-runtime"
    additions = normalize_runtime_int(diff["additions"]) || 0
    deletions = normalize_runtime_int(diff["deletions"]) || 0
    files_changed = normalize_runtime_int(diff["filesChanged"]) || length(files)

    summary =
      if files_changed > 0 do
        [
          %{
            "id" => "#{task_id}-diff-summary",
            "label" => "#{files_changed} file(s) changed",
            "status" => runtime["status"] || "done",
            "depth" => 0,
            "kind" => "diff",
            "added" => additions,
            "removed" => deletions
          }
        ]
      else
        []
      end

    file_nodes =
      files
      |> Enum.take(10)
      |> Enum.with_index()
      |> Enum.map(fn {file, index} ->
        path = file["path"] || file["name"] || "file"

        %{
          "id" => "#{task_id}-file-#{index}",
          "label" => runtime_file_label(file),
          "status" => runtime["status"] || "done",
          "depth" => 1,
          "kind" => "edit",
          "target" => Path.basename(to_string(path)),
          "added" => normalize_runtime_int(file["additions"]) || 0,
          "removed" => normalize_runtime_int(file["deletions"]) || 0
        }
      end)

    summary ++ file_nodes
  end

  defp runtime_file_label(file) when is_map(file) do
    path = normalize_string(file["path"]) || normalize_string(file["name"]) || "file"
    status = normalize_string(file["status"]) || "M"
    "#{status} #{path}"
  end

  defp normalize_runtime_payload(runtime) when is_map(runtime) do
    diff = runtime["diff"] || runtime[:diff] || %{}
    controls = runtime["controls"] || runtime[:controls] || %{}

    %{}
    |> maybe_put(
      "taskId",
      normalize_string(runtime["taskId"] || runtime[:taskId] || runtime["task_id"])
    )
    |> maybe_put("provider", normalize_string(runtime["provider"] || runtime[:provider]))
    |> maybe_put("status", normalize_string(runtime["status"] || runtime[:status]))
    |> maybe_put(
      "repoId",
      normalize_string(runtime["repoId"] || runtime[:repoId] || runtime["repo_id"])
    )
    |> maybe_put(
      "repoName",
      normalize_string(runtime["repoName"] || runtime[:repoName] || runtime["repo_name"])
    )
    |> maybe_put("cwd", normalize_string(runtime["cwd"] || runtime[:cwd]))
    |> maybe_put(
      "workMode",
      normalize_string(runtime["workMode"] || runtime[:workMode] || runtime["work_mode"])
    )
    |> maybe_put(
      "durationMs",
      normalize_runtime_int(runtime["durationMs"] || runtime[:durationMs])
    )
    |> maybe_put("dirtyBefore", runtime_bool(runtime["dirtyBefore"] || runtime[:dirtyBefore]))
    |> maybe_put(
      "dirtyBeforeCount",
      normalize_runtime_int(runtime["dirtyBeforeCount"] || runtime[:dirtyBeforeCount])
    )
    |> maybe_put(
      "exitStatus",
      normalize_runtime_int(runtime["exitStatus"] || runtime[:exitStatus])
    )
    |> maybe_put("command", normalize_runtime_command(runtime["command"] || runtime[:command]))
    |> maybe_put("diff", normalize_runtime_diff(diff))
    |> maybe_put("controls", normalize_runtime_controls(controls))
  end

  defp normalize_runtime_payload(_), do: nil

  defp normalize_runtime_enc(value) when is_binary(value) do
    if String.starts_with?(value, "arte1.") and byte_size(value) <= 200_000 do
      value
    else
      nil
    end
  end

  defp normalize_runtime_enc(_), do: nil

  defp normalize_runtime_command(command) when is_map(command) do
    %{}
    |> maybe_put("executable", normalize_string(command["executable"] || command[:executable]))
    |> maybe_put("display", normalize_string(command["display"] || command[:display]))
    |> maybe_put("args", normalize_runtime_args(command["args"] || command[:args]))
  end

  defp normalize_runtime_command(_), do: nil

  defp normalize_runtime_args(args) when is_list(args) do
    args
    |> Enum.map(&to_string/1)
    |> Enum.map(&truncate(&1, 300))
    |> Enum.take(40)
  end

  defp normalize_runtime_args(_), do: nil

  defp normalize_runtime_diff(diff) when is_map(diff) do
    files =
      (diff["files"] || diff[:files] || [])
      |> Enum.map(&normalize_runtime_file/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(@max_runtime_files)

    %{}
    |> maybe_put("git", runtime_bool(diff["git"] || diff[:git]))
    |> maybe_put(
      "filesChanged",
      normalize_runtime_int(diff["filesChanged"] || diff[:filesChanged]) || length(files)
    )
    |> maybe_put("additions", normalize_runtime_int(diff["additions"] || diff[:additions]) || 0)
    |> maybe_put("deletions", normalize_runtime_int(diff["deletions"] || diff[:deletions]) || 0)
    |> maybe_put("files", files)
    |> maybe_put("patch", runtime_patch(diff["patch"] || diff[:patch]))
    |> maybe_put("patchTruncated", runtime_bool(diff["patchTruncated"] || diff[:patchTruncated]))
  end

  defp normalize_runtime_diff(_), do: nil

  defp normalize_runtime_file(file) when is_map(file) do
    path = normalize_string(file["path"] || file[:path])
    name = normalize_string(file["name"] || file[:name]) || (path && Path.basename(path))

    if is_nil(path) and is_nil(name) do
      nil
    else
      %{}
      |> maybe_put("path", path || name)
      |> maybe_put("name", name || path)
      |> maybe_put("status", normalize_string(file["status"] || file[:status]) || "M")
      |> maybe_put("additions", normalize_runtime_int(file["additions"] || file[:additions]) || 0)
      |> maybe_put("deletions", normalize_runtime_int(file["deletions"] || file[:deletions]) || 0)
    end
  end

  defp normalize_runtime_file(_), do: nil

  defp normalize_runtime_controls(controls) when is_map(controls) do
    %{}
    |> maybe_put("canCancel", runtime_bool(controls["canCancel"] || controls[:canCancel]))
    |> maybe_put("canRevert", runtime_bool(controls["canRevert"] || controls[:canRevert]))
  end

  defp normalize_runtime_controls(_), do: nil

  defp normalize_team_metadata(opts) do
    suppress? =
      Keyword.get(opts, :suppress_visible) == true or
        truthy_opt?(Keyword.get(opts, :suppress_visible))

    %{}
    |> maybe_put("agentWorkerTeamMode", normalize_string(Keyword.get(opts, :team_mode)))
    |> maybe_put("agentWorkerTeamRunId", normalize_string(Keyword.get(opts, :team_run_id)))
    |> maybe_put("agentWorkerTeamWorker", normalize_string(Keyword.get(opts, :team_worker)))
    |> maybe_put(
      "agentWorkerTeamWorkers",
      normalize_team_workers(Keyword.get(opts, :team_workers))
    )
    |> maybe_put("agentWorkerLeadWorker", normalize_string(Keyword.get(opts, :lead_worker)))
    |> maybe_put("agentWorkerTeamRole", normalize_string(Keyword.get(opts, :team_role)))
    |> maybe_put("suppressVisible", if(suppress?, do: true))
    |> maybe_put("agentWorkerSuppressVisible", if(suppress?, do: true))
    |> maybe_put("agentBridgeComputerId", normalize_string(Keyword.get(opts, :computer_id)))
    |> maybe_put("agentBridgeComputerLabel", normalize_string(Keyword.get(opts, :computer_label)))
  end

  defp merge_team_runtime(runtime, opts) do
    suppress? =
      Keyword.get(opts, :suppress_visible) == true or
        truthy_opt?(Keyword.get(opts, :suppress_visible))

    team =
      %{}
      |> maybe_put("teamMode", normalize_string(Keyword.get(opts, :team_mode)))
      |> maybe_put("teamRunId", normalize_string(Keyword.get(opts, :team_run_id)))
      |> maybe_put("teamWorker", normalize_string(Keyword.get(opts, :team_worker)))
      |> maybe_put("teamWorkers", normalize_team_workers(Keyword.get(opts, :team_workers)))
      |> maybe_put("leadWorker", normalize_string(Keyword.get(opts, :lead_worker)))
      |> maybe_put("teamRole", normalize_string(Keyword.get(opts, :team_role)))
      |> maybe_put("suppressVisible", if(suppress?, do: true))
      |> maybe_put("computerId", normalize_string(Keyword.get(opts, :computer_id)))
      |> maybe_put("computerLabel", normalize_string(Keyword.get(opts, :computer_label)))

    cond do
      map_size(team) == 0 -> runtime
      is_map(runtime) -> Map.merge(runtime, team)
      true -> Map.put(team, "status", "done")
    end
  end

  defp normalize_team_workers(values) when is_list(values) do
    values
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_team_workers(_), do: []

  defp normalize_runtime_int(value) when is_integer(value), do: value

  defp normalize_runtime_int(value) when is_float(value), do: round(value)

  defp normalize_runtime_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp normalize_runtime_int(_), do: nil

  defp runtime_bool(value) when is_boolean(value), do: value
  defp runtime_bool(value) when is_binary(value), do: truthy?(value)
  defp runtime_bool(value) when is_integer(value), do: value != 0
  defp runtime_bool(_), do: nil

  defp runtime_patch(value) when is_binary(value), do: truncate(value, @max_runtime_patch_bytes)
  defp runtime_patch(_), do: nil

  defp put_node_shape(event, tool, input) do
    {kind, target} = tool_kind_and_target(tool, input)

    event =
      event
      |> Map.put("kind", kind)
      |> maybe_put("target", target)
      |> maybe_put_subagent_type(kind, input)

    case patch_stats(tool, input) do
      {added, removed} when added > 0 or removed > 0 ->
        event |> Map.put("added", added) |> Map.put("removed", removed)

      _ ->
        event
    end
  end

  defp maybe_put_subagent_type(event, "task", input) when is_map(input) do
    maybe_put(
      event,
      "subagentType",
      normalize_string(input["subagent_type"] || input["subagentType"])
    )
  end

  defp maybe_put_subagent_type(event, _kind, _input), do: event

  defp copy_node_shape(node, event) do
    ["kind", "target", "added", "removed", "depth", "parentId", "subagentType"]
    |> Enum.reduce(node, fn key, acc ->
      case Map.get(event, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp tool_kind_and_target(tool, input) when is_map(input) do
    t = tool |> to_string() |> String.downcase()

    path =
      input["file_path"] ||
        input["filePath"] ||
        input["target_file"] ||
        input["targetFile"] ||
        input["path"] ||
        input["notebook_path"] ||
        first_patch_path(input)

    parsed_patch_target = patch_target(input)

    cond do
      t in ["read", "read_file", "notebookread", "view", "cat", "open"] ->
        {"read", target_basename(path)}

      t in [
        "edit",
        "search_replace",
        "multiedit",
        "notebookedit",
        "str_replace",
        "str_replace_editor",
        "update",
        "apply_patch",
        "applypatch"
      ] ->
        {"edit", parsed_patch_target || target_basename(path)}

      t in ["write", "write_file", "create", "createfile", "new_file"] ->
        {"write", parsed_patch_target || target_basename(path)}

      t in [
        "bash",
        "shell",
        "exec",
        "run",
        "command",
        "terminal",
        "run_terminal_command"
      ] ->
        {"bash", short_target(input["command"] || input["cmd"])}

      t in [
        "grep",
        "search",
        "glob",
        "find",
        "ripgrep",
        "rg",
        "list_dir",
        "list_dir_tree"
      ] ->
        {"search",
         short_target(input["pattern"] || input["query"] || input["target_directory"] || path)}

      t in ["webfetch", "websearch", "fetch", "web_search", "web_fetch", "browse", "open_page"] ->
        {"web", short_target(input["url"] || input["query"] || input["domain"])}

      t in ["task", "agent", "dispatch_agent", "spawn_subagent", "get_command_or_subagent_output"] ->
        {"task", short_target(input["description"] || input["prompt"] || input["command"])}

      t in ["todowrite", "todo", "todo_write"] ->
        {"todo", nil}

      not is_nil(mcp_progress_target(t, input)) ->
        {"mcp", mcp_progress_target(t, input)}

      t in ["use_tool", "search_tool"] ->
        case mcp_progress_target(to_string(input["tool_name"] || input["toolName"] || ""), input) do
          nil -> {"tool", short_target(input["tool_name"] || input["query"] || input["name"])}
          target -> {"mcp", target}
        end

      true ->
        {"tool", target_basename(path) || short_target(input["command"])}
    end
  end

  defp tool_kind_and_target(tool, _input), do: {to_string(tool) |> String.downcase(), nil}

  defp pretty_mcp_tool_label(tool) when is_binary(tool) do
    pretty = tool |> String.replace("_", " ") |> String.trim()

    cond do
      pretty == "" -> ""
      String.match?(pretty, ~r/^ask\s+fable$/i) -> "ask advisor"
      String.match?(pretty, ~r/^fable$/i) -> "ask advisor"
      true -> pretty
    end
  end

  defp pretty_mcp_tool_label(_), do: ""

  defp mcp_progress_target(tool_name, input) when is_binary(tool_name) do
    t = String.trim(tool_name)

    cond do
      t == "" ->
        nil

      String.match?(t, ~r/^mcp__/i) or String.contains?(t, "__") ->
        cleaned = t |> String.replace_prefix("mcp__", "") |> String.replace_prefix("MCP__", "")
        parts = String.split(cleaned, "__", parts: 2)

        case parts do
          [server, tool] when server != "" and tool != "" ->
            pretty = pretty_mcp_tool_label(tool)
            "#{server} · #{pretty}"

          _ ->
            short_target(t)
        end

      is_map(input) and is_binary(input["server"]) and is_binary(input["tool"]) ->
        pretty = pretty_mcp_tool_label(input["tool"])
        "#{input["server"]} · #{pretty}"

      true ->
        nil
    end
  end

  defp mcp_progress_target(_, _), do: nil

  defp target_basename(path) when is_binary(path) do
    case Path.basename(String.trim(path)) do
      "" -> nil
      base -> base
    end
  end

  defp target_basename(_), do: nil

  defp short_target(value) do
    value
    |> safe_text()
    |> normalize_string()
    |> case do
      nil -> nil
      text -> text |> String.replace(~r/\s+/, " ") |> truncate(80)
    end
  end

  defp patch_stats(tool, input) when is_map(input) do
    t = tool |> to_string() |> String.downcase()
    parsed_patch_stats = apply_patch_stats(input)

    cond do
      parsed_patch_stats != nil and
          t in ["edit", "search_replace", "multiedit", "update", "apply_patch", "applypatch"] ->
        parsed_patch_stats

      t in ["write", "write_file", "create", "createfile", "new_file"] ->
        {line_count(input["content"] || input["file_text"] || input["text"]), 0}

      t in [
        "edit",
        "search_replace",
        "notebookedit",
        "str_replace",
        "str_replace_editor",
        "update"
      ] ->
        {line_count(
           input["new_string"] || input["newString"] || input["new_str"] || input["new_source"]
         ),
         line_count(
           input["old_string"] || input["oldString"] || input["old_str"] || input["old_source"]
         )}

      t in ["multiedit"] ->
        (input["edits"] || [])
        |> Enum.reduce({0, 0}, fn edit, {add, del} ->
          {add + line_count(edit["new_string"] || edit["newString"]),
           del + line_count(edit["old_string"] || edit["oldString"])}
        end)

      true ->
        nil
    end
  end

  defp patch_stats(_tool, _input), do: nil

  defp line_count(value) when is_binary(value) do
    case String.trim_trailing(value, "\n") do
      "" -> 0
      trimmed -> trimmed |> String.split("\n") |> length()
    end
  end

  defp line_count(_), do: 0

  defp progress_event_from_line(line, worker) do
    worker = parser_worker(worker)

    with {:ok, event} when is_map(event) <- Jason.decode(line),
         tool_event when is_map(tool_event) <-
           Enum.find(tool_events_from_decoded(worker, [event]), fn event ->
             event["providerEventType"] != "tool_result"
           end) do
      Map.put(tool_event, "status", "running")
    else
      _ -> nil
    end
  end

  defp content_blocks_from_event(%{"message" => %{"content" => content}}),
    do: content_blocks_from_value(content)

  defp content_blocks_from_event(%{"content" => content}), do: content_blocks_from_value(content)
  defp content_blocks_from_event(_), do: []

  defp content_blocks_from_value(content) when is_list(content),
    do: Enum.filter(content, &is_map/1)

  defp content_blocks_from_value(content) when is_map(content), do: [content]
  defp content_blocks_from_value(_), do: []

  defp content_blocks_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join("\n")
    |> normalize_string()
  end

  defp content_blocks_text(_), do: nil

  defp visible_response_text(text, events) do
    text = normalize_string(text) || "The command finished without returning text."

    case activity_summary(events) do
      nil -> text
      summary -> text <> "\n\nActivity\n" <> summary
    end
  end

  defp activity_summary([]), do: nil

  defp activity_summary(events) do
    events
    |> Enum.take(@max_activity_summary_items)
    |> Enum.map(fn event ->
      label = event["label"] || event["tool"] || "Tool"
      status = event["status"] || "running"
      "- #{label} (#{status})"
    end)
    |> Enum.join("\n")
    |> then(fn summary ->
      extra = length(events) - @max_activity_summary_items
      if extra > 0, do: summary <> "\n- #{extra} more tool event(s)", else: summary
    end)
    |> normalize_string()
  end

  defp tool_label(provider, tool, input) do
    t = tool |> to_string()
    mcp = mcp_progress_target(t, input || %{})

    cond do
      is_binary(mcp) and mcp != "" ->
        leaf =
          mcp
          |> String.split(" · ")
          |> List.last()
          |> to_string()
          |> String.trim()

        if leaf != "", do: "MCP · #{leaf}", else: "MCP · #{mcp}"

      true ->
        case tool_detail(input) do
          nil -> "#{provider} #{tool}"
          detail -> "#{provider} #{tool}: #{truncate(detail, 96)}"
        end
    end
  end

  defp tool_detail(input) when is_map(input) do
    [
      "command",
      "cmd",
      "description",
      "path",
      "file_path",
      "filePath",
      "pattern",
      "query",
      "url",
      "prompt"
    ]
    |> Enum.find_value(fn key ->
      input
      |> Map.get(key)
      |> safe_text()
      |> normalize_string()
    end)
  end

  defp tool_detail(input), do: input |> safe_text() |> normalize_string()

  defp safe_payload(value) when is_map(value) do
    value
    |> Enum.take(12)
    |> Map.new(fn {key, value} ->
      key = to_string(key)

      if secret_key?(key) do
        {key, "[redacted]"}
      else
        {key, safe_payload(value)}
      end
    end)
  end

  defp safe_payload(value) when is_list(value) do
    value
    |> Enum.take(12)
    |> Enum.map(&safe_payload/1)
  end

  defp safe_payload(value) when is_binary(value), do: truncate(value, @max_payload_preview_bytes)
  defp safe_payload(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp safe_payload(value), do: value |> inspect() |> truncate(@max_payload_preview_bytes)

  defp safe_text(nil), do: nil

  defp safe_text(value) when is_binary(value), do: truncate(value, @max_payload_preview_bytes)

  defp safe_text(value) when is_list(value) do
    value
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"content" => content} -> safe_text(content)
      item when is_binary(item) -> item
      item -> inspect(item)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> truncate(@max_payload_preview_bytes)
  end

  defp safe_text(value) when is_map(value),
    do: value |> safe_payload() |> inspect() |> truncate(@max_payload_preview_bytes)

  defp safe_text(value), do: value |> inspect() |> truncate(@max_payload_preview_bytes)

  defp secret_key?(key) do
    key
    |> String.downcase()
    |> then(
      &String.contains?(&1, ["secret", "token", "password", "api_key", "apikey", "private_key"])
    )
  end

  defp append_once(values, value) do
    if value in values, do: values, else: values ++ [value]
  end

  defp unique_event_id(prefix, index), do: "#{prefix}-#{index}"

  defp map_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp split_complete_lines(data) do
    parts = String.split(data, "\n", trim: false)

    case Enum.reverse(parts) do
      [tail | reversed_complete] -> {Enum.reverse(reversed_complete), tail}
      [] -> {[], ""}
    end
  end

  defp safe_line_callback(callback, line) do
    callback.(String.trim_trailing(line, "\r"))
  rescue
    error ->
      Logger.debug("[LocalAgentWorker] progress callback failed: #{inspect(error)}")
      :ok
  end

  defp shell_join(args) do
    Enum.map_join(args, " ", &shell_quote/1)
  end

  defp shell_quote(arg) do
    value = to_string(arg)

    if Regex.match?(~r/^[A-Za-z0-9_\/:.,=@%+\-]+$/, value) do
      value
    else
      "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
    end
  end

  defp fallback_output(output) do
    output
    |> to_string()
    |> String.trim()
    |> truncate(6_000)
    |> case do
      "" -> "The command finished without returning text."
      text -> text
    end
  end

  defp command_failed_text(worker, status, text) do
    """
    #{worker.label} command exited with status #{status}.

    #{truncate(text, 5_500)}
    """
    |> String.trim()
  end

  defp error_message(worker, :local_agent_workers_disabled) do
    "#{worker.label} local worker is disabled. Set `VIBE_LOCAL_AGENT_WORKERS=1` on the server that runs Vibe to allow @#{worker.handle} tasks."
  end

  defp error_message(worker, {:command_not_found, command}) do
    "#{worker.label} command `#{command}` was not found on this server."
  end

  defp error_message(worker, {:timeout, timeout_ms, output}) do
    "#{worker.label} timed out after #{div(timeout_ms, 1000)}s.\n\n#{truncate(output, 4_000)}"
  end

  defp error_message(worker, :missing_prompt), do: "Tell @#{worker.handle} what task to run."

  defp error_message(worker, reason) do
    "#{worker.label} could not run this task: #{inspect(reason)}"
  end

  defp normalize_handle(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("@")
    |> String.downcase()
    |> case do
      "antigravity" -> "agy"
      other -> other
    end
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil

  defp truthy?(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    normalized in ["1", "true", "yes", "on", "enabled"]
  end

  defp truthy?(_), do: false

  defp truncate(text, limit) when is_binary(text) and byte_size(text) > limit do
    String.slice(text, 0, limit) <> "\n...[truncated]"
  end

  defp truncate(text, _limit), do: text
end
