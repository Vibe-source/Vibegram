defmodule VibeWeb.UserSocketTest do
  use ExUnit.Case, async: true

  alias VibeWeb.UserSocket

  describe "extract_connect_token/2" do
    test "prefers x-vibe-auth Bearer header over query token" do
      connect_info = %{
        x_headers: [{"x-vibe-auth", "Bearer header-login-token"}]
      }

      assert UserSocket.extract_connect_token(
               %{"token" => "query-login-token"},
               connect_info
             ) == "header-login-token"
    end

    test "accepts x-vibe-auth without requiring a query token" do
      connect_info = %{x_headers: [{"x-vibe-auth", "Bearer only-header-token"}]}

      assert UserSocket.extract_connect_token(%{}, connect_info) == "only-header-token"

      assert UserSocket.extract_connect_token(%{"token" => ""}, connect_info) ==
               "only-header-token"
    end

    test "accepts raw x-vibe-auth token as defensive fallback" do
      connect_info = %{x_headers: [{"x-vibe-auth", "  raw-login-token  "}]}

      assert UserSocket.extract_connect_token(%{}, connect_info) == "raw-login-token"
    end

    test "falls back to query token for legacy clients" do
      assert UserSocket.extract_connect_token(%{"token" => "legacy-query-token"}, %{}) ==
               "legacy-query-token"

      assert UserSocket.extract_connect_token(
               %{"token" => "legacy-query-token"},
               %{x_headers: []}
             ) == "legacy-query-token"
    end

    test "ignores Authorization header (not forwarded as usable x- header)" do
      connect_info = %{
        x_headers: [{"authorization", "Bearer should-not-be-used"}]
      }

      assert UserSocket.extract_connect_token(%{}, connect_info) == nil

      assert UserSocket.extract_connect_token(%{"token" => "query-ok"}, connect_info) ==
               "query-ok"
    end

    test "rejects missing, blank, and undefined tokens" do
      assert UserSocket.extract_connect_token(%{}, %{}) == nil
      assert UserSocket.extract_connect_token(%{"token" => ""}, %{x_headers: []}) == nil
      assert UserSocket.extract_connect_token(%{"token" => "undefined"}, %{}) == nil

      assert UserSocket.extract_connect_token(%{}, %{x_headers: [{"x-vibe-auth", "Bearer "}]}) ==
               nil

      assert UserSocket.extract_connect_token(
               %{},
               %{x_headers: [{"x-vibe-auth", "Bearer undefined"}]}
             ) == nil

      assert UserSocket.extract_connect_token(%{}, %{x_headers: [{"x-vibe-auth", "undefined"}]}) ==
               nil

      assert UserSocket.extract_connect_token(%{}, %{x_headers: [{"x-vibe-auth", "   "}]}) == nil
    end

    test "Bearer prefix is case-insensitive" do
      connect_info = %{x_headers: [{"x-vibe-auth", "bearer CaseToken"}]}
      assert UserSocket.extract_connect_token(%{}, connect_info) == "CaseToken"
    end
  end

  describe "parse_auth_header_value/1" do
    test "parses Bearer and raw forms" do
      assert UserSocket.parse_auth_header_value("Bearer abc") == "abc"
      assert UserSocket.parse_auth_header_value("abc") == "abc"
      assert UserSocket.parse_auth_header_value("") == nil
      assert UserSocket.parse_auth_header_value(nil) == nil
    end
  end
end
