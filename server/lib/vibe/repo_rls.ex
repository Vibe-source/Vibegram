defmodule Vibe.RepoRLS do
  @moduledoc """
  Helpers for running DB operations with an RLS user context.
  """

  require Logger
  alias Vibe.Repo

  @spec with_user(String.t() | nil, (() -> any())) :: any()
  def with_user(nil, fun) when is_function(fun, 0), do: fun.()

  def with_user(user_id, fun) when is_binary(user_id) and is_function(fun, 0) do
    trimmed = String.trim(user_id)

    if trimmed == "" do
      fun.()
    else
      run_with_user(trimmed, fun)
    end
  end

  def with_user(_user_id, fun) when is_function(fun, 0), do: fun.()

  defp run_with_user(user_id, fun) do
    if Repo.in_transaction?() do
      set_local_user(user_id)
      fun.()
    else
      case Repo.transaction(fn ->
             set_local_user(user_id)
             fun.()
           end) do
        {:ok, result} -> result
        {:error, reason} ->
          Logger.error("[RepoRLS] with_user transaction failed user_id=#{user_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp set_local_user(user_id) do
    Repo.query!("SELECT set_config('app.current_user_id', $1, true)", [user_id])
    :ok
  end
end
