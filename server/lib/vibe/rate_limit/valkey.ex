defmodule Vibe.RateLimit.Valkey do
  @moduledoc """
  Fixed-window rate limiting via Redix (INCR + PEXPIRE on a window-slot key).
  """
  @behaviour Vibe.RateLimit.Backend
  require Logger

  @impl true
  def hit(key, max_requests, window_ms) do
    now = System.system_time(:millisecond)
    slot = div(now, window_ms)
    window_end_ms = (slot + 1) * window_ms
    redis_key = "vibe:rl:" <> inspect(key) <> ":" <> Integer.to_string(slot)

    try do
      case Redix.command(Vibe.Redix, ["INCR", redis_key]) do
        {:ok, count} ->
          if count == 1, do: Redix.command(Vibe.Redix, ["PEXPIRE", redis_key, window_ms])

          if count > max_requests do
            {:error, window_end_ms - now, window_end_ms}
          else
            {:ok, max_requests - count, window_end_ms}
          end

        {:error, reason} ->
          fallback(key, max_requests, window_ms, reason)
      end
    catch
      :exit, reason -> fallback(key, max_requests, window_ms, reason)
    end
  end

  defp fallback(key, max_requests, window_ms, reason) do
    Vibe.Cache.fetch({:rate_limit_valkey_error_logged}, 60_000, fn ->
      Logger.error(
        "[Vibe.RateLimit.Valkey] Redix unavailable, failing open to ETS: #{inspect(reason)}"
      )

      true
    end)

    Vibe.RateLimit.ETS.hit(key, max_requests, window_ms)
  end
end
