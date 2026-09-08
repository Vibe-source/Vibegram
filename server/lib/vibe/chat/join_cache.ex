defmodule Vibe.Chat.JoinCache do
  @moduledoc """
  Caches the DM agent-shadow lookup done on `chat:<id>` join, per chat and user.
  Role stays uncached — authorization is never served stale. See docs/capacity-500k.md §3.8.
  """

  @table :chat_join_cache
  @ttl_ms 60_000
  # Above this size a `put` sweeps expired rows.
  @sweep_threshold 10_000

  @topic "vibe:cache"

  @doc "Cache TTL in milliseconds."
  def ttl_ms, do: @ttl_ms

  @doc """
  Resolve the DM's agent-shadow participant, caching per `{chat_id, user_id}`.
  `nil` is cached too, so a human DM pays no repeat query.
  """
  def fetch_dm_agent(chat_id, user_id, loader)
      when is_binary(chat_id) and is_binary(user_id) and is_function(loader, 0) do
    key = {chat_id, user_id}

    case lookup(key) do
      {:hit, value} ->
        value

      :miss ->
        value = loader.()
        put(key, value)
        value
    end
  end

  def fetch_dm_agent(_chat_id, _user_id, loader) when is_function(loader, 0), do: loader.()

  @doc "Drop every entry for a chat, on this node and the others."
  def invalidate(chat_id) when is_binary(chat_id) do
    invalidate_local(chat_id)
    Phoenix.PubSub.broadcast(Vibe.PubSub, @topic, {:chat_join_cache_invalidate, chat_id})
    :ok
  end

  def invalidate(_chat_id), do: :ok

  @doc "Local-only delete — called here and by Vibe.Cache's cross-node relay."
  def invalidate_local(chat_id) when is_binary(chat_id) do
    ensure_table()
    :ets.match_delete(@table, {{chat_id, :_}, :_, :_})
    :ok
  end

  def invalidate_local(_chat_id), do: :ok

  @doc """
  Drop the whole table on this node and the others.
  Agent edits are rare and are not keyed by chat, so they clear rather than match.
  """
  def invalidate_all do
    invalidate_all_local()
    Phoenix.PubSub.broadcast(Vibe.PubSub, @topic, :chat_join_cache_invalidate_all)
    :ok
  end

  @doc false
  def invalidate_all_local do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp lookup(key) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, expires_at, value}] ->
        if now_ms() < expires_at do
          {:hit, value}
        else
          :ets.delete(@table, key)
          :miss
        end

      _ ->
        :miss
    end
  end

  defp put(key, value) do
    ensure_table()
    maybe_sweep()
    :ets.insert(@table, {key, now_ms() + @ttl_ms, value})
    value
  end

  defp maybe_sweep do
    if :ets.info(@table, :size) > @sweep_threshold do
      :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:<, :"$1", now_ms()}], [true]}])
    end

    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table, {:read_concurrency, true}])
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end
