defmodule Vibe.Cache do
  @moduledoc """
  Node-local ETS cache with cross-node invalidation over Phoenix.PubSub.
  """
  use GenServer

  @table :vibe_cache
  @topic "vibe:cache"
  @sweep_above 50_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Cached value for `key`, else computes it with `fun.()`, stores it for `ttl_ms`, and returns it."
  def fetch(key, ttl_ms, fun) when is_tuple(key) and is_function(fun, 0) do
    case get(key) do
      {:ok, value} ->
        value

      :miss ->
        value = fun.()
        put(key, value, ttl_ms)
        value
    end
  end

  def get(key) when is_tuple(key) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        {:ok, value}

      [{^key, _value, _expires_at}] ->
        :ets.delete(@table, key)
        :miss

      [] ->
        :miss
    end
  end

  def put(key, value, ttl_ms) when is_tuple(key) do
    ensure_table()
    maybe_sweep()
    :ets.insert(@table, {key, value, System.monotonic_time(:millisecond) + ttl_ms})
    :ok
  end

  @doc "Local-only delete of one exact key. Does not broadcast — use invalidate/1 for that."
  def delete(key) when is_tuple(key) do
    ensure_table()
    :ets.delete(@table, key)
    :ok
  end

  @doc "Local-only delete of every key whose leading elements match `prefix`."
  def delete_prefix(prefix) when is_tuple(prefix) do
    ensure_table()
    psize = tuple_size(prefix)
    plist = Tuple.to_list(prefix)

    :ets.foldl(
      fn {key, _value, _expires_at}, acc ->
        if is_tuple(key) and tuple_size(key) >= psize and
             Enum.take(Tuple.to_list(key), psize) == plist do
          [key | acc]
        else
          acc
        end
      end,
      [],
      @table
    )
    |> Enum.each(&:ets.delete(@table, &1))

    :ok
  end

  @doc "Deletes `key` (or, given a shorter tuple, every key under that prefix) here and on every node."
  def invalidate(key) when is_tuple(key) do
    delete_prefix(key)
    Phoenix.PubSub.broadcast(Vibe.PubSub, @topic, {:cache_invalidate, key})
    :ok
  end

  @impl true
  def init(_opts) do
    ensure_table()
    Phoenix.PubSub.subscribe(Vibe.PubSub, @topic)
    {:ok, %{}}
  end

  # Remote (or looped-back local) invalidation broadcast.
  @impl true
  def handle_info({:cache_invalidate, key}, state) do
    delete_prefix(key)
    {:noreply, state}
  end

  # Relays Vibe.ChatHomeCache's cross-node invalidation (separate ETS table.
  def handle_info({:chat_home_cache_invalidate, user_id}, state) do
    Vibe.ChatHomeCache.invalidate_user_local(user_id)
    {:noreply, state}
  end

  # Same relay for the join cache (agent-shadow resolution).
  def handle_info({:chat_join_cache_invalidate, chat_id}, state) do
    Vibe.Chat.JoinCache.invalidate_local(chat_id)
    {:noreply, state}
  end

  def handle_info(:chat_join_cache_invalidate_all, state) do
    Vibe.Chat.JoinCache.invalidate_all_local()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end

  defp maybe_sweep do
    if :ets.info(@table, :size) > @sweep_above do
      now = System.monotonic_time(:millisecond)

      :ets.foldl(
        fn {key, _value, expires_at}, acc -> if expires_at <= now, do: [key | acc], else: acc end,
        [],
        @table
      )
      |> Enum.each(&:ets.delete(@table, &1))
    end
  end
end
