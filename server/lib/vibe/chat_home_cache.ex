defmodule Vibe.ChatHomeCache do
  @moduledoc false

  @table :chat_home_cache
  @ttl_ms 10_000

  def fetch(user_id, loader) when is_binary(user_id) and is_function(loader, 0) do
    now = now_ms()

    case lookup(user_id, now) do
      {:hit, value} ->
        value

      :miss ->
        value = loader.()
        put(user_id, value, now + @ttl_ms)
        value
    end
  end

  # Deletes locally, then broadcasts so a second node drops its own copy too.
  def invalidate_user(user_id) when is_binary(user_id) do
    invalidate_user_local(user_id)
    Phoenix.PubSub.broadcast(Vibe.PubSub, "vibe:cache", {:chat_home_cache_invalidate, user_id})
    :ok
  end

  def invalidate_user(_user_id), do: :ok

  @doc "Local-only delete — called directly here and by Vibe.Cache's cross-node relay."
  def invalidate_user_local(user_id) when is_binary(user_id) do
    ensure_table()
    :ets.delete(@table, user_id)
    :ok
  end

  def invalidate_user_local(_user_id), do: :ok

  def invalidate_users(user_ids) when is_list(user_ids) do
    Enum.each(user_ids, &invalidate_user/1)
    :ok
  end

  def invalidate_users(_user_ids), do: :ok

  defp lookup(user_id, now) do
    ensure_table()

    case :ets.lookup(@table, user_id) do
      [{^user_id, expires_at, value}] when expires_at > now -> {:hit, value}
      [{^user_id, _expires_at, _value}] ->
        :ets.delete(@table, user_id)
        :miss

      _ ->
        :miss
    end
  end

  defp put(user_id, value, expires_at) do
    ensure_table()
    :ets.insert(@table, {user_id, expires_at, value})
    value
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, {:read_concurrency, true}])

      _tid ->
        :ok
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
