defmodule Vibe.Chat.JoinCacheTest do
  @moduledoc "Join-cache keying and invalidation. No DB: the loader stands in for the query."

  use ExUnit.Case, async: false

  alias Vibe.Chat.JoinCache

  setup do
    JoinCache.invalidate_all_local()
    :ok
  end

  defp counting_loader(value) do
    test_pid = self()
    fn ->
      send(test_pid, :loaded)
      value
    end
  end

  defp chat_id, do: "cache-test-#{System.unique_integer([:positive])}"

  test "loads once on a miss, then serves the hit without calling the loader" do
    chat = chat_id()

    assert JoinCache.fetch_dm_agent(chat, "user-a", counting_loader(:agent)) == :agent
    assert_received :loaded

    assert JoinCache.fetch_dm_agent(chat, "user-a", counting_loader(:other)) == :agent
    refute_received :loaded
  end

  test "nil is cached too, so a human DM pays no repeat query" do
    chat = chat_id()

    assert JoinCache.fetch_dm_agent(chat, "user-a", counting_loader(nil)) == nil
    assert_received :loaded

    assert JoinCache.fetch_dm_agent(chat, "user-a", counting_loader(:agent)) == nil
    refute_received :loaded
  end

  test "two users of one chat do not share an entry" do
    chat = chat_id()

    assert JoinCache.fetch_dm_agent(chat, "human", counting_loader(:agent)) == :agent
    assert_received :loaded

    assert JoinCache.fetch_dm_agent(chat, "shadow", counting_loader(nil)) == nil
    assert_received :loaded
  end

  test "invalidate drops every user's entry for that chat and leaves others" do
    chat = chat_id()
    untouched = chat_id()

    JoinCache.fetch_dm_agent(chat, "human", counting_loader(:agent))
    JoinCache.fetch_dm_agent(chat, "shadow", counting_loader(:agent))
    JoinCache.fetch_dm_agent(untouched, "human", counting_loader(:agent))
    flush()

    JoinCache.invalidate_local(chat)

    assert JoinCache.fetch_dm_agent(chat, "human", counting_loader(:fresh)) == :fresh
    assert_received :loaded
    assert JoinCache.fetch_dm_agent(chat, "shadow", counting_loader(:fresh)) == :fresh
    assert_received :loaded

    assert JoinCache.fetch_dm_agent(untouched, "human", counting_loader(:fresh)) == :agent
    refute_received :loaded
  end

  test "invalidate_all clears every chat" do
    a = chat_id()
    b = chat_id()

    JoinCache.fetch_dm_agent(a, "human", counting_loader(:agent))
    JoinCache.fetch_dm_agent(b, "human", counting_loader(:agent))
    flush()

    JoinCache.invalidate_all_local()

    assert JoinCache.fetch_dm_agent(a, "human", counting_loader(:fresh)) == :fresh
    assert_received :loaded
    assert JoinCache.fetch_dm_agent(b, "human", counting_loader(:fresh)) == :fresh
    assert_received :loaded
  end

  test "a non-binary id bypasses the cache rather than crashing" do
    assert JoinCache.fetch_dm_agent(nil, "human", counting_loader(:agent)) == :agent
    assert_received :loaded

    assert JoinCache.fetch_dm_agent(nil, "human", counting_loader(:agent)) == :agent
    assert_received :loaded
  end

  test "ttl is a minute" do
    assert JoinCache.ttl_ms() == 60_000
  end

  defp flush do
    receive do
      :loaded -> flush()
    after
      0 -> :ok
    end
  end
end
