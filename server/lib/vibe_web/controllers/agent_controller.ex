defmodule VibeWeb.AgentController do
  @moduledoc """
  REST API controller for AI Agent.
  Supports both streaming (SSE) and regular responses.
  """

  use VibeWeb, :controller
  require Logger

  alias Vibe.AI.Agent, as: AiAgent

  @doc """
  Handle a chat message and stream the response via SSE.
  """
  def chat(conn, %{"message" => message} = params) do
    images = params["images"] || []
    history = params["history"] || []
    user_id = conn.assigns.current_user.id
    chat_id = params["chatId"] || params["chat_id"]

    conn = conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    callback = fn
      %{type: :text, content: chunk} ->
        send_sse_event(conn, "chunk", %{text: chunk})

      %{type: :progress, label: label} ->
        send_sse_event(conn, "progress", %{label: label})

      %{type: :tool_result, tool: tool, result: result} ->
        send_sse_event(conn, "tool_result", %{tool: tool, result: result})

      %{type: :subagent} = event ->
        send_sse_event(conn, "subagent", Map.delete(event, :type))

      %{type: type} = event ->
        send_sse_event(conn, to_string(type), Map.delete(event, :type))

      _other ->
        :ok
    end

    case AiAgent.stream_response(
           message,
           callback,
           history: history,
           images: images,
           user_id: user_id,
           chat_id: chat_id
         ) do
      {:ok, _full_response, _runtime_state} ->
        send_sse_event(conn, "done", %{success: true})

      {:ok, _full_response} ->
        send_sse_event(conn, "done", %{success: true})

      {:error, reason} ->
        send_sse_event(conn, "error", %{message: to_string(reason)})
    end

    conn
  end

  @doc """
  Non-streaming chat endpoint.
  Returns the complete response as JSON.
  """
  def chat_sync(conn, %{"message" => message} = params) do
    images = params["images"] || []
    history = params["history"] || []
    user_id = conn.assigns.current_user.id
    chat_id = params["chatId"] || params["chat_id"]

    {:ok, collected} = Agent.start_link(fn -> "" end)

    callback = fn
      %{type: :text, content: chunk} ->
        Agent.update(collected, fn acc -> acc <> chunk end)
      _ ->
        :ok
    end

    try do
      case AiAgent.stream_response(
             message,
             callback,
             history: history,
             images: images,
             user_id: user_id,
             chat_id: chat_id
           ) do
        {:ok, full_response, _runtime_state} ->
          json(conn, %{
            success: true,
            response: full_response
          })

        {:ok, full_response} ->
          json(conn, %{
            success: true,
            response: full_response
          })

        {:error, reason} ->
          conn
          |> put_status(500)
          |> json(%{error: to_string(reason)})
      end
    after
      Agent.stop(collected)
    end
  end

  defp send_sse_event(conn, event, data) do
    chunk = "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
    case Plug.Conn.chunk(conn, chunk) do
      {:ok, _conn} -> :ok
      {:error, reason} -> Logger.warning("SSE chunk failed: #{inspect(reason)}")
    end
  end

  @doc """
  Health check for the agent service.
  """
  def health(conn, _params) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_API_KEY")

    json(conn, %{
      status: "ok",
      agent_configured: api_key != nil,
      tools: [
        "search_music",
        "search_google",
        "analyze_image",
        "analyze_document",
        "delegate_to_subagent"
      ]
    })
  end
end
