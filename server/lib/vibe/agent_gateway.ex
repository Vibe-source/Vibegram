defmodule Vibe.AgentGateway do
  @moduledoc """
  Signed client from the chat core to the isolated agent-runtime service
  (docs/agent-platform-v1.md §3.1-§3.2).
  """

  require Logger

  alias Vibe.Agent
  alias Vibe.AgentUsage
  alias Vibe.Chat
  alias Vibe.AI.StandaloneAgent

  @service_name "core"

  @doc "URL + signing key both present — the only precondition for any call here."
  def enabled? do
    present?(runtime_url()) and present?(hmac_key())
  end

  @doc "`VIBE_AI_KILL_SWITCH=1` refuses every new dispatch, embedded or isolated."
  def kill_switch?, do: System.get_env("VIBE_AI_KILL_SWITCH") == "1"

  @doc "Env override (`VIBE_AGENT_EXECUTION_MODE`) wins over the agent's own column."
  def execution_mode_for(%Agent{} = agent) do
    cond do
      System.get_env("VIBE_AGENT_EXECUTION_MODE") == "embedded" -> "embedded"
      System.get_env("VIBE_AGENT_EXECUTION_MODE") == "isolated" -> "isolated"
      VibeContracts.ToolBundles.sandbox?(agent.enabled_tools || []) -> "isolated"
      true -> agent.execution_mode || "embedded"
    end
  end

  @doc """
  Builds a `RunRequest` from `%{agent:.
  """
  def start_run(params) when is_map(params) do
    if kill_switch?() do
      {:error, :kill_switch}
    else
      agent = Map.fetch!(params, :agent) |> Vibe.Repo.preload(:agent_user)
      chat_id = Map.fetch!(params, :chat_id)

      case AgentUsage.check_entitlement(agent.owner_user_id) do
        :ok -> do_start_run(agent, chat_id, params)
        err -> err
      end
    end
  end

  defp do_start_run(agent, chat_id, params) do
    body =
      %{
        "idempotencyKey" => params[:idempotency_key],
        "source" => params[:source] || "chat",
        "agentId" => agent.id,
        "agentUserId" => agent.agent_user_id,
        "ownerUserId" => agent.owner_user_id,
        "requesterUserId" => params[:requester_user_id],
        "chatId" => chat_id,
        "chatKind" => Chat.get_room_type(chat_id) || "dm",
        "replyToId" => params[:reply_to_id],
        "parentRunId" => params[:parent_run_id],
        "input" => %{
          "text" => params[:text] || "",
          "attachments" => normalize_attachments(params[:attachments] || [])
        },
        "agentProfile" => agent_profile(agent),
        "context" => %{
          "history" => history_for(agent, chat_id, params[:requester_user_id]),
          "participants" => participants_for(chat_id, agent.agent_user_id)
        },
        "capabilities" => capabilities_for(agent)
      }
      |> compact()

    request(:post, "/internal/v1/runs", body)
  end

  @doc "`POST /internal/v1/runs/:runId/cancel`."
  def cancel(run_id, reason, requested_by_user_id) do
    request(:post, "/internal/v1/runs/#{run_id}/cancel", %{
      "reason" => reason,
      "requestedByUserId" => requested_by_user_id
    })
  end

  @doc "`POST /internal/v1/runs/:runId/decisions` — approve/reject/answer/grant/deny."
  def decision(run_id, params, _opts \\ []) do
    body =
      %{
        "decisionId" => params[:decisionId] || params["decisionId"],
        "kind" => params[:kind] || params["kind"],
        "outcome" => params[:outcome] || params["outcome"],
        "answer" => params[:answer] || params["answer"],
        "actorUserId" => params[:actorUserId] || params["actorUserId"],
        "actionId" => params[:actionId] || params["actionId"]
      }
      |> compact()

    request(:post, "/internal/v1/runs/#{run_id}/decisions", body)
  end

  @doc "`GET /internal/v1/runs/:runId` → `{run, events}`."
  def get_run(run_id), do: request(:get, "/internal/v1/runs/#{run_id}", nil)

  @doc "`POST /internal/v1/agents/:agentId/computer` — ensures a sandboxed computer."
  def ensure_computer(agent_id) do
    request(:post, "/internal/v1/agents/#{agent_id}/computer", %{"action" => "ensure"})
  end

  @doc "`GET /internal/v1/agents/:agentId/computer/preview` — latest screenshot."
  def computer_preview(agent_id) do
    request(:get, "/internal/v1/agents/#{agent_id}/computer/preview", nil)
  end

  @doc "`POST /internal/v1/agents/:agentId/computer/session` — `{viewerId, fps?, width?, quality?}`."
  def computer_session(agent_id, params) when is_map(params) do
    request(:post, "/internal/v1/agents/#{agent_id}/computer/session", compact(params))
  end

  @doc "`DELETE /internal/v1/agents/:agentId/computer/session/:sessionId`."
  def close_computer_session(agent_id, session_id) do
    request(:delete, "/internal/v1/agents/#{agent_id}/computer/session/#{session_id}", nil)
  end

  @doc "`GET …/computer/frame?since=` — `{:ok, :no_change}` on 204, nothing newer than `since`."
  def computer_frame(agent_id, opts \\ []) do
    since = Keyword.get(opts, :since, 0)
    query = "since=#{since}" <> session_query(Keyword.get(opts, :session))
    request(:get, "/internal/v1/agents/#{agent_id}/computer/frame?#{query}", nil)
  end

  defp session_query(session) when is_binary(session) and session != "",
    do: "&session=#{URI.encode_www_form(session)}"

  defp session_query(_session), do: ""

  @doc "`GET /internal/v1/agents/:agentId/computer/state`."
  def computer_state(agent_id) do
    request(:get, "/internal/v1/agents/#{agent_id}/computer/state", nil)
  end

  @doc "`GET …/computer/exec-log?since=&limit=` — the shell runs the agent made here."
  def computer_exec_log(agent_id, opts \\ []) do
    query = URI.encode_query(%{"since" => Keyword.get(opts, :since, 0), "limit" => Keyword.get(opts, :limit, 40)})
    request(:get, "/internal/v1/agents/#{agent_id}/computer/exec-log?#{query}", nil)
  end

  @doc "`GET …/computer/tree?path=&depth=` — a directory listing from inside the sandbox."
  def computer_tree(agent_id, opts \\ []) do
    query = URI.encode_query(%{"path" => Keyword.get(opts, :path, ""), "depth" => Keyword.get(opts, :depth, 2)})
    request(:get, "/internal/v1/agents/#{agent_id}/computer/tree?#{query}", nil)
  end

  @doc "`GET …/computer/file?path=` — one file, base64, capped by the gateway."
  def computer_file(agent_id, path) do
    request(:get, "/internal/v1/agents/#{agent_id}/computer/file?#{URI.encode_query(%{"path" => path})}", nil)
  end

  @doc "`POST …/computer/control` — `{action:\"grant\"|\"release\", sessionId, ttlSeconds?}`."
  def computer_control(agent_id, params) when is_map(params) do
    request(:post, "/internal/v1/agents/#{agent_id}/computer/control", compact(params))
  end

  @doc "`POST …/computer/input` — `{sessionId, kind, x?, y?, text?, key?, deltaY?, url?}`."
  def computer_input(agent_id, params) when is_map(params) do
    request(:post, "/internal/v1/agents/#{agent_id}/computer/input", compact(params))
  end

  @doc "`POST …/browser/navigate` — `{url}`. Creates the sandbox on first use."
  def browser_navigate(agent_id, params) when is_map(params) do
    request(:post, "/internal/v1/agents/#{agent_id}/browser/navigate", compact(params))
  end

  @doc "`POST …/browser/action` — `{kind, ref?, selector?, x?, y?, text?}`."
  def browser_action(agent_id, params) when is_map(params) do
    request(:post, "/internal/v1/agents/#{agent_id}/browser/action", compact(params))
  end

  @doc "`GET …/browser/screenshot?maxWidth=` — `{imageBase64, mime, width, height}`."
  def browser_screenshot(agent_id, max_width) when is_integer(max_width) do
    request(:get, "/internal/v1/agents/#{agent_id}/browser/screenshot?maxWidth=#{max_width}", nil)
  end

  @doc "`POST /internal/v1/voice/sessions` — params is `{agentId,userId,chatId,agentProfile}`."
  def voice_session(params), do: request(:post, "/internal/v1/voice/sessions", params)

  @doc "`POST /internal/v1/provider-invoke` — an already-authenticated provider payload."
  def provider_invoke(%Agent{} = agent, payload) when is_map(payload) do
    body = Map.merge(%{"source" => "provider", "agentId" => agent.id}, payload)
    request(:post, "/internal/v1/provider-invoke", body)
  end

  @doc "`GET /internal/v1/healthz`."
  def healthy? do
    match?({:ok, %{"ok" => true}}, request(:get, "/internal/v1/healthz", nil))
  end

  @doc "Same `agentProfile` shape sent in a RunRequest — reused by `/internal/v1/provider-auth`."
  def agent_profile(%Agent{} = agent) do
    %{
      "displayName" => agent.display_name,
      "username" => agent.agent_user && agent.agent_user.username,
      "systemPrompt" => agent.system_prompt,
      "persona" => agent.persona,
      "modelProvider" => agent.model_provider,
      "modelId" => agent.model_id,
      "thinkingLevel" => "medium",
      "enabledTools" => agent.enabled_tools || [],
      "outputModes" => agent.output_modes || [],
      "autonomyMode" => agent.autonomy_mode,
      "approvalRules" => agent.approval_rules || %{},
      "budgets" => %{
        "dailyCents" => agent.cost_budget_daily,
        "monthlyCents" => agent.cost_budget_monthly
      },
      "adminMode" => agent.admin_mode || false
    }
  end

  defp history_for(_agent, _chat_id, nil), do: []

  defp history_for(agent, chat_id, requester_user_id) do
    StandaloneAgent.history_for_runtime(chat_id, requester_user_id, agent.agent_user_id)
  end

  defp participants_for(chat_id, agent_user_id) do
    ids = Chat.get_participant_ids(chat_id)
    agents = teammate_agents(ids)
    names = participant_names(ids)

    Enum.map(ids, fn id ->
      teammate = agents[id]

      %{
        "userId" => id,
        "isAgent" => not is_nil(teammate),
        "isSelf" => id == agent_user_id,
        "username" => names[id],
        "name" => (teammate && teammate.display_name) || names[id],
        "role" => teammate && (teammate.persona || teammate.display_name)
      }
    end)
  end

  defp teammate_agents(user_ids) do
    import Ecto.Query

    Vibe.Agent
    |> where([a], a.agent_user_id in ^user_ids)
    |> select([a], {a.agent_user_id, a})
    |> Vibe.Repo.all()
    |> Map.new()
  end

  defp participant_names(user_ids) do
    import Ecto.Query

    Vibe.Accounts.User
    |> where([u], u.id in ^user_ids)
    |> select([u], {u.id, u.username})
    |> Vibe.Repo.all()
    |> Map.new()
  end

  defp normalize_attachments(attachments) do
    Enum.map(attachments, fn a ->
      type = to_string(a[:type] || a["type"] || "file")

      kind =
        case type do
          "image" -> "image"
          "voice" -> "audio"
          "audio" -> "audio"
          _ -> "document"
        end

      %{
        "kind" => kind,
        "url" => a[:url] || a["url"],
        "mime" => a[:mime] || a["mime"],
        "name" => a[:name] || a["name"]
      }
      |> compact()
    end)
  end

  defp capabilities_for(agent) do
    VibeContracts.ToolBundles.capabilities(agent.enabled_tools || [])
  end

  defp request(method, path, body) do
    if enabled?() do
      json_body = if body, do: Jason.encode!(body), else: ""
      headers = build_headers(method, path, json_body)
      url = runtime_url() <> path

      case http_client().(method, url, headers, json_body) do
        {:ok, %{status: 204}} ->
          {:ok, :no_change}

        {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
          {:ok, decode(resp_body)}

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:http_error, status, decode(resp_body)}}

        {:error, :unreachable} ->
          {:error, :unreachable}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :disabled}
    end
  end

  defp build_headers(method, path, json_body) do
    method_str = method |> Atom.to_string() |> String.upcase()

    case VibeContracts.ServiceAuth.headers(hmac_key(), method_str, path, json_body,
           service: @service_name
         ) do
      {:error, reason} -> raise ArgumentError, "internal auth signing failed: #{inspect(reason)}"
      headers -> headers ++ [{"content-type", "application/json"}]
    end
  end

  defp http_client do
    Application.get_env(:vibe, :agent_gateway_http, &default_http_request/4)
  end

  defp default_http_request(method, url, headers, body) do
    request = Finch.build(method, url, headers, body)

    case Finch.request(request, Vibe.Finch, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:ok, %{status: status, body: resp_body}}

      {:error, reason} ->
        Logger.warning("[AgentGateway] request failed url=#{url} reason=#{inspect(reason)}")
        {:error, classify_error(reason)}
    end
  end

  defp classify_error(%Mint.TransportError{reason: reason})
       when reason in [:econnrefused, :closed, :timeout, :nxdomain],
       do: :unreachable

  defp classify_error(_reason), do: :request_failed

  defp decode(body) when is_binary(body) and body != "" do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode(_body), do: %{}

  defp compact(map) when is_map(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end

  defp runtime_url, do: String.trim_trailing(System.get_env("VIBE_AGENT_RUNTIME_URL") || "", "/")
  defp hmac_key, do: System.get_env("VIBE_INTERNAL_HMAC_KEY") || ""
  defp present?(v), do: is_binary(v) and String.trim(v) != ""
end
