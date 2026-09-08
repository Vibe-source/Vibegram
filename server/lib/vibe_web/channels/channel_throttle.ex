defmodule VibeWeb.ChannelThrottle do
  @moduledoc """
  Per-user sliding-window limits for socket events. HTTP plugs never see channel
  traffic, so without this one socket could flood a chat at any rate it liked.
  """

  @table :channel_throttle
  @sweep_after_ms 60_000

  # bucket => {max events, window ms}
  @limits %{
    message: {30, 10_000},
    edit: {30, 60_000},
    delete: {30, 60_000},
    react: {60, 60_000},
    typing: {20, 10_000}
  }

  @doc "Returns `:ok`, or throws `{:throttled, reply}` for a `catch` clause in `handle_in`."
  def check!(user_id, bucket) do
    case check(user_id, bucket) do
      :ok -> :ok
      {:error, reply} -> throw({:throttled, reply})
    end
  end

  @doc "Sliding window per `{user_id, bucket}`; a limited call is not counted."
  def check(user_id, bucket) do
    {max, window} = Map.fetch!(@limits, bucket)
    ensure_table()
    now = System.system_time(:millisecond)
    key = {user_id, bucket}

    recent =
      case :ets.lookup(@table, key) do
        [{^key, stamps}] -> Enum.filter(stamps, &(&1 > now - window))
        [] -> []
      end

    if length(recent) >= max do
      oldest = List.last(recent)
      {:error, %{reason: "rate_limited", retryAfterMs: max(oldest + window - now, 0)}}
    else
      :ets.insert(@table, {key, [now | recent]})
      maybe_sweep(now)
      :ok
    end
  end

  def limits, do: @limits

  @doc "Idempotent; the application creates the table at boot so it outlives any channel."
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table, {:write_concurrency, true}])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp maybe_sweep(now) do
    if :rand.uniform(200) == 1 do
      cutoff = now - @sweep_after_ms
      :ets.select_delete(@table, [{{:_, [:"$1" | :_]}, [{:<, :"$1", cutoff}], [true]}])
    end

    :ok
  end
end
