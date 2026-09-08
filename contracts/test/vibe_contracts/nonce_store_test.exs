defmodule VibeContracts.NonceStoreTest do
  use ExUnit.Case, async: false

  alias VibeContracts.NonceStore

  defp unique_nonce, do: "store-#{System.unique_integer([:positive])}"

  test "the store is supervised and owns the replay table" do
    assert NonceStore.ready?()
    assert is_pid(Process.whereis(NonceStore))
  end

  test "a nonce is unseen once, then seen" do
    nonce = unique_nonce()

    refute NonceStore.seen?(nonce, 600)
    assert NonceStore.seen?(nonce, 600)
  end

  test "sweep drops expired entries and keeps live ones" do
    expired = unique_nonce()
    live = unique_nonce()

    refute NonceStore.seen?(expired, -10)
    refute NonceStore.seen?(live, 600)

    NonceStore.sweep()

    refute NonceStore.seen?(expired, 600)
    assert NonceStore.seen?(live, 600)
  end

  test "seen? reports :unavailable when the table is gone, and the supervisor brings it back" do
    :ets.delete(NonceStore.table())
    refute NonceStore.ready?()
    assert NonceStore.seen?(unique_nonce(), 600) == :unavailable

    ref = Process.monitor(NonceStore)
    Process.exit(Process.whereis(NonceStore), :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}, 1_000

    wait_for_ready()
    assert NonceStore.ready?()
  end

  defp wait_for_ready(attempts \\ 100) do
    cond do
      NonceStore.ready?() ->
        :ok

      attempts == 0 ->
        flunk("NonceStore did not restart")

      true ->
        Process.sleep(10)
        wait_for_ready(attempts - 1)
    end
  end
end
