defmodule Vibe.Accounts.LoginThrottle do
  @moduledoc """
  Per-identifier login-failure throttle: 10 failures inside a 15-minute window locks that
  identifier for 15 minutes; a success clears it.
  """

  @table :login_throttle
  @max_failures 10
  @window_ms 15 * 60 * 1000
  @lock_ms 15 * 60 * 1000

  @doc "True if this identifier is currently locked out."
  @spec locked?(String.t()) :: boolean()
  def locked?(identifier) do
    case lookup(normalize(identifier)) do
      nil -> false
      {_count, _window_started, locked_until} -> now_ms() < locked_until
    end
  end

  @doc "Records a failed attempt; locks the identifier once the threshold is crossed."
  @spec record_failure(String.t()) :: :ok
  def record_failure(identifier) do
    key = normalize(identifier)

    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        now = now_ms()
        {count, window_started, locked_until} = current_window(key, now)
        new_count = count + 1
        new_locked_until = if new_count >= @max_failures, do: now + @lock_ms, else: locked_until

        :ets.insert(@table, {key, new_count, window_started, new_locked_until})
        :ok
    end
  end

  @doc "Clears throttle state on a successful login."
  @spec record_success(String.t()) :: :ok
  def record_success(identifier) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete(@table, normalize(identifier))
    end

    :ok
  end

  defp current_window(key, now) do
    case lookup(key) do
      nil -> {0, now, 0}
      {_count, window_started, locked_until} when now - window_started > @window_ms -> {0, now, locked_until}
      {count, window_started, locked_until} -> {count, window_started, locked_until}
    end
  end

  defp lookup(key) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@table, key) do
          [{^key, count, window_started, locked_until}] -> {count, window_started, locked_until}
          _ -> nil
        end
    end
  end

  defp normalize(identifier), do: identifier |> to_string() |> String.trim() |> String.downcase()

  defp now_ms, do: System.system_time(:millisecond)
end
