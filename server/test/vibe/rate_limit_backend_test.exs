defmodule Vibe.RateLimitBackendTest do
  use ExUnit.Case, async: false

  alias Vibe.RateLimit
  alias Vibe.RateLimit.ETS
  alias Vibe.RateLimit.Valkey

  describe "Vibe.RateLimit.ETS" do
    test "allows requests under the limit and counts remaining down" do
      key = {:rl_test, :ets, System.unique_integer([:positive])}

      assert {:ok, 1, reset_at} = ETS.hit(key, 2, 60_000)
      assert reset_at > System.system_time(:millisecond)
      assert {:ok, 0, _reset_at} = ETS.hit(key, 2, 60_000)
    end

    test "blocks once the limit is exceeded and reports a positive retry_after" do
      key = {:rl_test, :ets_block, System.unique_integer([:positive])}

      assert {:ok, 0, _} = ETS.hit(key, 1, 60_000)
      assert {:error, retry_after_ms, reset_at} = ETS.hit(key, 1, 60_000)
      assert retry_after_ms > 0
      assert reset_at > System.system_time(:millisecond)
    end

    test "a fresh window after the ttl elapses allows again" do
      key = {:rl_test, :ets_window, System.unique_integer([:positive])}
      assert {:ok, 0, _} = ETS.hit(key, 1, 10)
      Process.sleep(20)
      assert {:ok, 0, _} = ETS.hit(key, 1, 10)
    end
  end

  describe "Vibe.RateLimit.Valkey" do
    test "fails open to the ETS backend when Vibe.Redix isn't running" do
      key = {:rl_test, :valkey_fallback, System.unique_integer([:positive])}

      assert {:ok, remaining, reset_at} = Valkey.hit(key, 5, 60_000)
      assert remaining == 4
      assert reset_at > System.system_time(:millisecond)
    end
  end

  describe "Vibe.RateLimit.backend/0" do
    test "defaults to ETS when RATE_LIMIT_BACKEND is unset" do
      original = System.get_env("RATE_LIMIT_BACKEND")
      System.delete_env("RATE_LIMIT_BACKEND")
      on_exit(fn -> restore_env("RATE_LIMIT_BACKEND", original) end)

      assert RateLimit.backend() == ETS
    end

    test "selects Valkey when RATE_LIMIT_BACKEND=valkey" do
      original = System.get_env("RATE_LIMIT_BACKEND")
      System.put_env("RATE_LIMIT_BACKEND", "valkey")
      on_exit(fn -> restore_env("RATE_LIMIT_BACKEND", original) end)

      assert RateLimit.backend() == Valkey
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
