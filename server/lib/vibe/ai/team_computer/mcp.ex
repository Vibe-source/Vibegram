defmodule Vibe.AI.TeamComputer.MCP do
  @moduledoc """
  MCP streamable-HTTP endpoint (`POST /internal/team-computer/mcp`) that gives the
  `claude` CLI a role worker runs the same sandboxed browser API-key agents get.

  Identity comes only from the bearer minted by `Vibe.AI.TeamComputer.Auth` — headers and
  query are never trusted — and every tool call broadcasts the `agent-preview` /
  `agent-computer` frames iOS already renders (docs/agent-computer-v1.md §3.2, §3.4).
  """

  use VibeWeb, :controller

  require Logger

  alias Vibe.AgentGateway
  alias Vibe.AI.TeamComputer.Auth

  @protocol_version "2025-06-18"
  @server_info %{"name" => "vibe-computer", "version" => "1"}
  @screenshot_max_width 900

  @tools [
    %{
      "name" => "browser_open",
      "description" =>
        "Open a URL in your sandboxed browser. The owner sees the page on their phone.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"url" => %{"type" => "string", "description" => "Absolute URL"}},
        "required" => ["url"]
      }
    },
    %{
      "name" => "browser_act",
      "description" => "Act on the open page: click, type, key, scroll or back.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ["click", "type", "key", "scroll", "back"]
          },
          "selector" => %{"type" => "string", "description" => "CSS selector"},
          "ref" => %{"type" => "string", "description" => "Element ref from a snapshot"},
          "x" => %{"type" => "number"},
          "y" => %{"type" => "number"},
          "text" => %{"type" => "string", "description" => "Text to type, or the key name"}
        },
        "required" => ["action"]
      }
    },
    %{
      "name" => "browser_screenshot",
      "description" => "Capture the viewport. For the owner to look at, not for reasoning.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "computer_request_control",
      "description" =>
        "Hand the browser to the owner so they can log in or approve something. Then wait.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "reason" => %{"type" => "string", "description" => "Why you need them"},
          "url" => %{"type" => "string"}
        },
        "required" => ["reason"]
      }
    }
  ]

  def handle(conn, params) do
    case authorize(conn) do
      {:ok, identity} -> dispatch(conn, identity, params)
      {:error, _reason} -> unauthorized(conn)
    end
  end

  defp authorize(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, identity} <- Auth.verify_run_token(String.trim(token)) do
      {:ok, identity}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(401)
    |> json(%{"error" => "unauthorized"})
  end

  defp dispatch(conn, _identity, %{"_json" => _batch}) do
    json(conn, error_response(nil, -32_600, "batch requests are not supported"))
  end

  defp dispatch(conn, identity, %{"method" => method} = request) do
    id = request["id"]
    args = request["params"] || %{}

    case method do
      "initialize" ->
        json(conn, result_response(id, initialize_result()))

      "notifications/initialized" ->
        send_resp(conn, 202, "")

      "notifications/cancelled" ->
        send_resp(conn, 202, "")

      "ping" ->
        json(conn, result_response(id, %{}))

      "tools/list" ->
        json(conn, result_response(id, %{"tools" => @tools}))

      "tools/call" ->
        json(conn, call_tool(identity, id, args))

      _ ->
        json(conn, error_response(id, -32_601, "unknown method #{method}"))
    end
  end

  defp dispatch(conn, _identity, _params) do
    json(conn, error_response(nil, -32_600, "invalid request"))
  end

  defp initialize_result do
    %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => @server_info
    }
  end

  defp call_tool(identity, id, %{"name" => name} = args) do
    arguments = args["arguments"] || %{}

    case run_tool(identity, name, arguments) do
      {:ok, content} -> result_response(id, %{"content" => content, "isError" => false})
      {:error, message} -> result_response(id, %{"content" => [text(message)], "isError" => true})
    end
  end

  defp call_tool(_identity, id, _args),
    do: error_response(id, -32_602, "tools/call needs a tool name")

  defp run_tool(identity, "browser_open", %{"url" => url}) when is_binary(url) do
    case AgentGateway.browser_navigate(identity.agent_user_id, %{"url" => url}) do
      {:ok, body} when is_map(body) ->
        broadcast_computer(identity, body, true)
        {:ok, [text("Opened #{body["url"] || url}#{title_suffix(body)}")]}

      other ->
        {:error, describe(other)}
    end
  end

  defp run_tool(_identity, "browser_open", _arguments), do: {:error, "browser_open needs a url"}

  defp run_tool(identity, "browser_act", arguments) do
    case action_body(arguments) do
      {:ok, body} ->
        case AgentGateway.browser_action(identity.agent_user_id, body) do
          {:ok, result} when is_map(result) ->
            broadcast_computer(identity, result, true)
            {:ok, [text("#{body["kind"]} ok#{title_suffix(result)}")]}

          other ->
            {:error, describe(other)}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp run_tool(identity, "browser_screenshot", _arguments) do
    case AgentGateway.browser_screenshot(identity.agent_user_id, @screenshot_max_width) do
      {:ok, %{"imageBase64" => image} = shot} when is_binary(image) ->
        broadcast_preview(identity, shot)

        {:ok,
         [
           text("Screenshot sent to the owner's screen."),
           %{"type" => "image", "data" => image, "mimeType" => shot["mime"] || "image/jpeg"}
         ]}

      other ->
        {:error, describe(other)}
    end
  end

  defp run_tool(identity, "computer_request_control", %{"reason" => reason})
       when is_binary(reason) do
    params = %{"action" => "grant", "holder" => "user", "reason" => reason}

    case AgentGateway.computer_control(identity.agent_user_id, params) do
      {:ok, body} when is_map(body) ->
        broadcast_control(identity, reason, body)
        {:ok, [text("Asked the owner to take control. Stop and wait for them to hand it back.")]}

      other ->
        {:error, describe(other)}
    end
  end

  defp run_tool(_identity, "computer_request_control", _arguments),
    do: {:error, "computer_request_control needs a reason"}

  defp run_tool(_identity, name, _arguments), do: {:error, "unknown tool #{name}"}

  defp action_body(arguments) when is_map(arguments) do
    kind = arguments["action"] || arguments["kind"]

    if is_binary(kind) and kind != "" do
      body =
        %{
          "kind" => kind,
          "selector" => arguments["selector"],
          "ref" => arguments["ref"],
          "x" => arguments["x"],
          "y" => arguments["y"],
          "text" => arguments["text"]
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      {:ok, body}
    else
      {:error, "browser_act needs an action"}
    end
  end

  defp action_body(_arguments), do: {:error, "browser_act needs an action"}

  defp broadcast_computer(identity, body, live) do
    broadcast(identity, "agent-computer", %{
      "url" => body["url"],
      "title" => body["title"],
      "live" => live,
      "holder" => "agent"
    })
  end

  defp broadcast_control(identity, reason, body) do
    broadcast(identity, "agent-computer", %{
      "url" => body["url"],
      "title" => body["title"],
      "live" => true,
      "holder" => "user",
      "reason" => reason,
      "expiresAt" => body["expiresAt"]
    })
  end

  defp broadcast_preview(identity, shot) do
    broadcast(identity, "agent-preview", %{
      "imageBase64" => shot["imageBase64"],
      "mime" => shot["mime"] || "image/jpeg",
      "width" => shot["width"],
      "height" => shot["height"],
      "label" => label_for(identity)
    })
  end

  defp broadcast(identity, event, payload) do
    frame =
      payload
      |> Map.merge(%{
        "chatId" => identity.chat_id,
        "runId" => identity.run_id,
        "agentUserId" => identity.agent_user_id,
        "ts" => System.system_time(:millisecond)
      })

    VibeWeb.Endpoint.broadcast!("chat:#{identity.chat_id}", event, frame)
    :ok
  rescue
    error ->
      Logger.warning("[TeamComputer] broadcast #{event} failed: #{inspect(error)}")
      :ok
  end

  defp label_for(identity) do
    worker = identity.worker || %{}
    worker[:label] || worker[:name] || "Computer"
  end

  defp title_suffix(%{"title" => title}) when is_binary(title) and title != "", do: " — #{title}"
  defp title_suffix(_body), do: ""

  defp describe({:error, {:http_error, status, body}}),
    do: "gateway returned #{status}: #{inspect(body)}"

  defp describe({:error, :not_configured}), do: "no computer is configured for this deployment"
  defp describe({:error, :not_available}), do: "this agent has no computer yet"
  defp describe({:error, :disabled}), do: "the agent runtime is disabled"
  defp describe({:error, :unreachable}), do: "the agent runtime is unreachable"
  defp describe({:error, reason}), do: "computer call failed: #{inspect(reason)}"
  defp describe(other), do: "unexpected computer response: #{inspect(other)}"

  defp text(message), do: %{"type" => "text", "text" => message}

  defp result_response(id, result),
    do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
end
