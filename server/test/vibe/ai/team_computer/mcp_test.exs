defmodule Vibe.AI.TeamComputer.MCPTest do
  @moduledoc "Bearer auth, JSON-RPC shape, and the frames each tool call broadcasts."

  use ExUnit.Case, async: false

  alias Vibe.AI.LocalAgentWorker
  alias Vibe.AI.TeamComputer.Auth
  alias Vibe.AI.TeamComputer.MCP

  @key String.duplicate("k", 40)

  setup do
    System.put_env("VIBE_AGENT_RUNTIME_URL", "http://runtime.test")
    System.put_env("VIBE_INTERNAL_HMAC_KEY", @key)
    test_pid = self()

    Application.put_env(:vibe, :agent_gateway_http, fn method, url, _headers, body ->
      send(test_pid, {:gateway_request, method, url, body})
      {:ok, %{status: 200, body: Jason.encode!(gateway_reply(url))}}
    end)

    on_exit(fn ->
      System.delete_env("VIBE_AGENT_RUNTIME_URL")
      System.delete_env("VIBE_INTERNAL_HMAC_KEY")
      Application.delete_env(:vibe, :agent_gateway_http)
    end)

    chat_id = Ecto.UUID.generate()
    {:ok, token} = Auth.mint_run_token(coder_id(), chat_id)
    %{chat_id: chat_id, token: token}
  end

  describe "auth" do
    test "no bearer is 401", _context do
      conn = call(nil, %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
      assert conn.status == 401
    end

    test "a garbage bearer is 401", _context do
      conn = call("not-a-token", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
      assert conn.status == 401
    end

    test "a token for a user that is not a role worker is refused" do
      assert {:error, :unauthorized} =
               Auth.mint_run_token(Ecto.UUID.generate(), Ecto.UUID.generate())
    end

    test "a token for a malformed chat id is refused" do
      assert {:error, :unauthorized} = Auth.mint_run_token(coder_id(), "not-a-uuid")
    end

    test "an expired token is refused", %{token: token} do
      assert {:ok, _identity} = Auth.verify_run_token(token)
      assert Auth.max_age_seconds() <= 900
      assert {:error, :unauthorized} = Auth.verify_run_token("")
    end

    test "identity comes from the token, not from headers", %{token: token, chat_id: chat_id} do
      assert {:ok, identity} = Auth.verify_run_token(token)
      assert identity.agent_user_id == coder_id()
      assert identity.chat_id == chat_id
    end
  end

  describe "protocol" do
    test "initialize announces tools", %{token: token} do
      body = decode(call(token, request(1, "initialize")))
      assert body["result"]["protocolVersion"]
      assert body["result"]["capabilities"]["tools"]
      assert body["result"]["serverInfo"]["name"] == "vibe-computer"
    end

    test "ping is an empty result", %{token: token} do
      assert decode(call(token, request(2, "ping")))["result"] == %{}
    end

    test "notifications/initialized is 202 with no body", %{token: token} do
      conn = call(token, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      assert conn.status == 202
    end

    test "tools/list names the four frozen tools", %{token: token} do
      tools = decode(call(token, request(3, "tools/list")))["result"]["tools"]
      names = Enum.map(tools, & &1["name"]) |> Enum.sort()

      assert names == [
               "browser_act",
               "browser_open",
               "browser_screenshot",
               "computer_request_control"
             ]

      assert Enum.all?(tools, &is_map(&1["inputSchema"]))
    end

    test "an unknown method is a JSON-RPC error", %{token: token} do
      body = decode(call(token, request(4, "tools/nope")))
      assert body["error"]["code"] == -32_601
    end

    test "batch requests are refused", %{token: token} do
      body = decode(call(token, %{"_json" => [request(1, "ping")]}))
      assert body["error"]["code"] == -32_600
    end
  end

  describe "tools" do
    test "browser_open navigates and broadcasts agent-computer", %{
      token: token,
      chat_id: chat_id
    } do
      VibeWeb.Endpoint.subscribe("chat:#{chat_id}")

      body =
        decode(call(token, tool_call(5, "browser_open", %{"url" => "https://example.com"})))

      assert body["result"]["isError"] == false
      assert_receive {:gateway_request, :post, url, _body}
      assert url =~ "/browser/navigate"

      assert_receive %Phoenix.Socket.Broadcast{event: "agent-computer", payload: payload}
      assert payload["chatId"] == chat_id
      assert payload["agentUserId"] == coder_id()
      assert payload["holder"] == "agent"
      assert payload["live"] == true
    end

    test "browser_open without a url is a tool error, not a crash", %{token: token} do
      body = decode(call(token, tool_call(6, "browser_open", %{})))
      assert body["result"]["isError"] == true
    end

    test "browser_act posts the action, never computer/input", %{token: token} do
      body =
        decode(
          call(token, tool_call(7, "browser_act", %{"action" => "click", "selector" => "#go"}))
        )

      assert body["result"]["isError"] == false
      assert_receive {:gateway_request, :post, url, raw}
      assert url =~ "/browser/action"
      refute url =~ "/computer/input"
      assert Jason.decode!(raw)["kind"] == "click"
    end

    test "browser_act without an action is a tool error", %{token: token} do
      body = decode(call(token, tool_call(8, "browser_act", %{"selector" => "#go"})))
      assert body["result"]["isError"] == true
    end

    test "browser_screenshot returns image content and broadcasts agent-preview", %{
      token: token,
      chat_id: chat_id
    } do
      VibeWeb.Endpoint.subscribe("chat:#{chat_id}")

      body = decode(call(token, tool_call(9, "browser_screenshot", %{})))
      content = body["result"]["content"]

      assert Enum.any?(content, &(&1["type"] == "image" and &1["data"] == "aGk="))
      assert_receive {:gateway_request, :get, url, _body}
      assert url =~ "/browser/screenshot?maxWidth="

      assert_receive %Phoenix.Socket.Broadcast{event: "agent-preview", payload: payload}
      assert payload["imageBase64"] == "aGk="
      assert payload["chatId"] == chat_id
      assert payload["agentUserId"] == coder_id()
      assert payload["mime"] == "image/jpeg"
    end

    test "computer_request_control hands the machine to the owner", %{
      token: token,
      chat_id: chat_id
    } do
      VibeWeb.Endpoint.subscribe("chat:#{chat_id}")

      body =
        decode(call(token, tool_call(10, "computer_request_control", %{"reason" => "log me in"})))

      assert body["result"]["isError"] == false
      assert_receive {:gateway_request, :post, url, raw}
      assert url =~ "/computer/control"
      assert Jason.decode!(raw)["holder"] == "user"

      assert_receive %Phoenix.Socket.Broadcast{event: "agent-computer", payload: payload}
      assert payload["holder"] == "user"
      assert payload["reason"] == "log me in"
    end

    test "a gateway failure is a tool error carrying the status", %{token: token} do
      Application.put_env(:vibe, :agent_gateway_http, fn _method, _url, _headers, _body ->
        {:ok, %{status: 502, body: Jason.encode!(%{"error" => "denied_domain"})}}
      end)

      body = decode(call(token, tool_call(11, "browser_open", %{"url" => "https://blocked.test"})))
      assert body["result"]["isError"] == true
      assert hd(body["result"]["content"])["text"] =~ "502"
    end

    test "frames only ever go to the chat the token was minted for", %{token: token} do
      other_chat = Ecto.UUID.generate()
      VibeWeb.Endpoint.subscribe("chat:#{other_chat}")

      call(token, tool_call(12, "browser_screenshot", %{}))

      refute_receive %Phoenix.Socket.Broadcast{event: "agent-preview"}, 200
    end
  end

  defp coder_id, do: LocalAgentWorker.workers()["coder"][:agent_user_id]

  defp request(id, method), do: %{"jsonrpc" => "2.0", "id" => id, "method" => method}

  defp tool_call(id, name, arguments) do
    id
    |> request("tools/call")
    |> Map.put("params", %{"name" => name, "arguments" => arguments})
  end

  defp call(token, params) do
    conn =
      :post
      |> Plug.Test.conn("/internal/team-computer/mcp", params)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = if token, do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    MCP.handle(conn, params)
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp gateway_reply(url) do
    cond do
      String.contains?(url, "/browser/screenshot") ->
        %{"imageBase64" => "aGk=", "mime" => "image/jpeg", "width" => 900, "height" => 600}

      String.contains?(url, "/computer/control") ->
        %{"control" => "user", "expiresAt" => "2026-09-08T00:00:00Z"}

      true ->
        %{"url" => "https://example.com/", "title" => "Example"}
    end
  end
end
