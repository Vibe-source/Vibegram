defmodule VibeContracts.RedactTest do
  use ExUnit.Case, async: true
  alias VibeContracts.Redact

  test "tool_input/1 redacts values whose key matches a sensitive pattern" do
    input = %{
      "secret" => "s1",
      "token" => "t1",
      "password" => "p1",
      "passwd" => "p2",
      "apiKey" => "k1",
      "api-key" => "k2",
      "api_key" => "k3",
      "Authorization" => "Bearer abc",
      "cookie" => "c1",
      "set-cookie" => "c2",
      "bearer" => "b1",
      "note" => "keep me"
    }

    out = Redact.tool_input(input)

    for key <- Map.keys(input) -- ["note"] do
      assert out[key] == "[redacted]", "expected #{key} to be redacted"
    end

    assert out["note"] == "keep me"
  end

  test "tool_input/1 recurses into nested maps and lists" do
    input = %{
      "outer" => %{"apiKey" => "x"},
      "items" => [%{"token" => "y"}, "plain", %{"ok" => "z"}]
    }

    out = Redact.tool_input(input)

    assert out["outer"]["apiKey"] == "[redacted]"
    assert [%{"token" => "[redacted]"}, "plain", %{"ok" => "z"}] = out["items"]
  end

  test "tool_input/1 matches atom keys too" do
    assert %{secret: "[redacted]"} = Redact.tool_input(%{secret: "x"})
  end

  test "tool_input/1 truncates long string values at 2000 chars" do
    exact = String.duplicate("a", 2000)
    over = String.duplicate("a", 2001)

    assert Redact.tool_input(%{"v" => exact})["v"] == exact
    truncated = Redact.tool_input(%{"v" => over})["v"]
    assert String.length(truncated) == 2001
    assert String.ends_with?(truncated, "…")
    assert String.starts_with?(truncated, String.duplicate("a", 2000))
  end

  test "tool_input/1 passes through non-string, non-collection values unchanged" do
    assert Redact.tool_input(%{"n" => 5, "b" => true, "nil" => nil}) == %{
             "n" => 5,
             "b" => true,
             "nil" => nil
           }
  end

  test "text/1 scrubs Bearer tokens" do
    assert Redact.text("Authorization: Bearer abc.def-123 more text") ==
             "Authorization: Bearer [redacted] more text"
  end

  test "text/1 scrubs sk-… and vak_… secrets" do
    assert Redact.text("key sk-abcdefghijklmno end") == "key [redacted] end"
    assert Redact.text("agent vak_ABCDEFGHIJ12345 key") == "agent [redacted] key"
  end

  test "text/1 scrubs an x-vibe-agent-secret header line" do
    assert Redact.text("x-vibe-agent-secret: sup3rsecret") == "x-vibe-agent-secret: [redacted]"
  end

  test "text/1 leaves ordinary text untouched" do
    assert Redact.text("nothing sensitive here") == "nothing sensitive here"
  end
end
