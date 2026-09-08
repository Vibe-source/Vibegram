defmodule VibeWeb.AgentBridgeSocketTest do
  use ExUnit.Case, async: true

  alias VibeWeb.AgentBridgeSocket

  describe "extract_connect_token/2" do
    test "extracts x-vibe-bridge-token Bearer header" do
      connect_info = %{
        x_headers: [{"x-vibe-bridge-token", "Bearer bridge-header-token"}]
      }

      assert AgentBridgeSocket.extract_connect_token(%{}, connect_info) == "bridge-header-token"
    end

    test "prefers header over query token" do
      connect_info = %{
        x_headers: [{"x-vibe-bridge-token", "Bearer from-header"}]
      }

      assert AgentBridgeSocket.extract_connect_token(
               %{"token" => "from-query"},
               connect_info
             ) == "from-header"
    end

    test "accepts raw x-vibe-bridge-token as defensive fallback" do
      connect_info = %{x_headers: [{"x-vibe-bridge-token", "raw-bridge-token"}]}

      assert AgentBridgeSocket.extract_connect_token(%{}, connect_info) == "raw-bridge-token"
    end

    test "falls back to query token for legacy daemons" do
      assert AgentBridgeSocket.extract_connect_token(%{"token" => "daemon-query-token"}, %{}) ==
               "daemon-query-token"
    end

    test "does not treat x-vibe-auth or authorization as bridge auth" do
      connect_info = %{
        x_headers: [
          {"x-vibe-auth", "Bearer login-token"},
          {"authorization", "Bearer other-token"}
        ]
      }

      assert AgentBridgeSocket.extract_connect_token(%{}, connect_info) == nil
    end

    test "rejects missing, blank, and undefined tokens" do
      assert AgentBridgeSocket.extract_connect_token(%{}, %{}) == nil
      assert AgentBridgeSocket.extract_connect_token(%{"token" => "  "}, %{x_headers: []}) == nil
      assert AgentBridgeSocket.extract_connect_token(%{"token" => "undefined"}, %{}) == nil

      assert AgentBridgeSocket.extract_connect_token(
               %{},
               %{x_headers: [{"x-vibe-bridge-token", "Bearer "}]}
             ) == nil

      assert AgentBridgeSocket.extract_connect_token(
               %{},
               %{x_headers: [{"x-vibe-bridge-token", "Bearer undefined"}]}
             ) == nil

      assert AgentBridgeSocket.extract_connect_token(
               %{},
               %{x_headers: [{"x-vibe-bridge-token", "undefined"}]}
             ) == nil
    end
  end
end
