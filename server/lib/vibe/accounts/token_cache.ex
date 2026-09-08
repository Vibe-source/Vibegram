defmodule Vibe.Accounts.TokenCache do
  @moduledoc """
  Short-TTL cache for `token hash -> sanitized user` resolution.
  """

  alias Vibe.Accounts.User

  @table :auth_token_cache
  @ttl_ms 60_000
  # Above this many entries a `put` sweeps expired rows first.
  @sweep_threshold 5_000

  @doc "Cache TTL in milliseconds."
  def ttl_ms, do: @ttl_ms

  @doc """
  Look up a cached user for `token_hash` (`Accounts.hash_session_token/1` of the bearer).
  """
  @spec fetch(binary()) :: {:ok, struct()} | :miss
  def fetch(token_hash) when is_binary(token_hash) and token_hash != "" do
    case :ets.whereis(@table) do
      :undefined ->
        emit(:miss)
        :miss

      _ ->
        case :ets.lookup(@table, token_hash) do
          [{^token_hash, _user_id, user, expires_at}] ->
            if now_ms() < expires_at do
              emit(:hit)
              {:ok, user}
            else
              :ets.delete(@table, token_hash)
              emit(:expired)
              :miss
            end

          _ ->
            emit(:miss)
            :miss
        end
    end
  end

  def fetch(_token_hash), do: :miss

  defp emit(result) do
    :telemetry.execute([:vibe, :cache, :token], %{count: 1}, %{result: result})
  end

  @doc "Cache a resolved user for `token_hash` for one TTL window."
  @spec put(binary(), struct()) :: :ok
  def put(token_hash, %User{id: user_id} = user) when is_binary(token_hash) and token_hash != "" do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        maybe_sweep()
        :ets.insert(@table, {token_hash, user_id, sanitize(user), now_ms() + @ttl_ms})
        :ok
    end
  end

  def put(_token_hash, _user), do: :ok

  defp sanitize(%User{} = user) do
    %{
      user
      | password_hash: nil,
        encrypted_private_key: nil,
        login_token: nil,
        push_token: nil,
        phone_number: nil
    }
  end

  @doc "Drop a single token's entry."
  @spec invalidate(binary()) :: :ok
  def invalidate(token_hash) when is_binary(token_hash) and token_hash != "" do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete(@table, token_hash)
    end

    :ok
  end

  def invalidate(_token_hash), do: :ok

  @doc """
  Drop every cached entry for a user.
  """
  @spec invalidate_user(String.t() | nil) :: :ok
  def invalidate_user(user_id) when is_binary(user_id) and user_id != "" do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.match_delete(@table, {:_, user_id, :_, :_})
    end

    :ok
  end

  def invalidate_user(_user_id), do: :ok

  defp maybe_sweep do
    if :ets.info(@table, :size) > @sweep_threshold do
      :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", now_ms()}], [true]}])
    end

    :ok
  end

  defp now_ms, do: System.system_time(:millisecond)
end
