defmodule Vibe.CacheTest do
  use ExUnit.Case, async: false

  setup do
    case start_supervised(Vibe.Cache) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "fetch computes once on a miss and returns the cached value on a hit" do
    key = {:cache_test, :fetch, System.unique_integer([:positive])}
    test_pid = self()

    value =
      Vibe.Cache.fetch(key, 60_000, fn ->
        send(test_pid, :computed)
        :computed_value
      end)

    assert value == :computed_value
    assert_received :computed

    value_again =
      Vibe.Cache.fetch(key, 60_000, fn ->
        send(test_pid, :computed_again)
        :other_value
      end)

    assert value_again == :computed_value
    refute_received :computed_again
  end

  test "get/put round trip, and a miss for an unknown key" do
    key = {:cache_test, :get_put, System.unique_integer([:positive])}
    assert Vibe.Cache.get(key) == :miss

    Vibe.Cache.put(key, "hello", 60_000)
    assert Vibe.Cache.get(key) == {:ok, "hello"}
  end

  test "an entry expires after its ttl" do
    key = {:cache_test, :ttl, System.unique_integer([:positive])}
    Vibe.Cache.put(key, "soon gone", 1)
    Process.sleep(5)
    assert Vibe.Cache.get(key) == :miss
  end

  test "delete/1 removes exactly one key" do
    a = {:cache_test, :delete, :a, System.unique_integer([:positive])}
    b = {:cache_test, :delete, :b, System.unique_integer([:positive])}
    Vibe.Cache.put(a, 1, 60_000)
    Vibe.Cache.put(b, 2, 60_000)

    Vibe.Cache.delete(a)

    assert Vibe.Cache.get(a) == :miss
    assert Vibe.Cache.get(b) == {:ok, 2}
  end

  test "delete_prefix/1 drops every key sharing the prefix and leaves the rest" do
    chat_id = "chat-#{System.unique_integer([:positive])}"
    other_chat_id = "chat-#{System.unique_integer([:positive])}"

    Vibe.Cache.put({:participant, chat_id, "user-a"}, true, 60_000)
    Vibe.Cache.put({:participant, chat_id, "user-b"}, true, 60_000)
    Vibe.Cache.put({:participant, other_chat_id, "user-a"}, true, 60_000)

    Vibe.Cache.delete_prefix({:participant, chat_id})

    assert Vibe.Cache.get({:participant, chat_id, "user-a"}) == :miss
    assert Vibe.Cache.get({:participant, chat_id, "user-b"}) == :miss
    assert Vibe.Cache.get({:participant, other_chat_id, "user-a"}) == {:ok, true}
  end

  test "invalidate/1 deletes locally and broadcasts on the vibe:cache topic" do
    :ok = Phoenix.PubSub.subscribe(Vibe.PubSub, "vibe:cache")
    key = {:cache_test, :invalidate, System.unique_integer([:positive])}
    Vibe.Cache.put(key, "will be gone", 60_000)

    Vibe.Cache.invalidate(key)

    assert Vibe.Cache.get(key) == :miss
    assert_receive {:cache_invalidate, ^key}
  end

  test "a remote invalidation broadcast is applied locally" do
    key = {:cache_test, :remote_invalidate, System.unique_integer([:positive])}
    Vibe.Cache.put(key, "remote will drop this", 60_000)

    Phoenix.PubSub.broadcast(Vibe.PubSub, "vibe:cache", {:cache_invalidate, key})

    assert wait_until(fn -> Vibe.Cache.get(key) == :miss end)
  end

  defp wait_until(fun, tries \\ 20)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end
end
