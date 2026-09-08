defmodule Vibe.RateLimit.ETS do
  @moduledoc """
  Node-local ETS rate limiter (fixed window) behind `Vibe.RateLimit.Backend`.
  """
  @behaviour Vibe.RateLimit.Backend

  @table :rate_limiter

  @impl true
  def hit(key, max_requests, window_ms) do
    ensure_table_exists()
    now = System.system_time(:millisecond)
    bucket_start = div(now, window_ms) * window_ms
    reset_at = bucket_start + window_ms
    entry = {key, bucket_start}

    count = :ets.update_counter(@table, entry, {2, 1}, {entry, 0})
    if count == 1, do: maybe_prune(window_ms)

    if count > max_requests do
      {:error, max(reset_at - now, 1000), reset_at}
    else
      {:ok, max_requests - count, reset_at}
    end
  end

  defp ensure_table_exists do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :set,
            :public,
            :named_table,
            {:read_concurrency, true},
            {:write_concurrency, true},
            {:decentralized_counters, true}
          ])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  @max_keys_default 200_000
  defp maybe_prune(window_ms) do
    max_keys = parse_positive_env("RATE_LIMIT_MAX_KEYS", @max_keys_default)

    if :ets.info(@table, :size) > max_keys do
      cutoff = System.system_time(:millisecond) - window_ms

      try do
        :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, {:+, :"$1", window_ms}, cutoff}], [true]}])
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  defp parse_positive_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      raw ->
        case Integer.parse(raw) do
          {value, _} when value > 0 -> value
          _ -> default
        end
    end
  end
end
