defmodule VibeContracts.NonceStore do
  @moduledoc """
  Owns the `vibe-internal-auth` replay cache (`VibeContracts.ServiceAuth`).

  Supervised so the table cannot disappear unnoticed: entries are written by the calling
  process into a public table, and verification fails closed if that table is gone.
  """

  use GenServer

  @table :vibe_internal_nonces
  @sweep_interval_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The replay table name."
  def table, do: @table

  @doc "True once the replay cache is available."
  def ready?, do: :ets.whereis(@table) != :undefined

  @doc """
  Records `nonce` for `ttl_seconds`. Returns `true` if it was already present, `false` for
  a first sighting, and `:unavailable` when the store is not running.
  """
  def seen?(nonce, ttl_seconds) do
    not :ets.insert_new(@table, {nonce, System.system_time(:second) + ttl_seconds})
  rescue
    ArgumentError -> :unavailable
  end

  @doc "Drops entries whose expiry has passed; returns how many were removed."
  def sweep do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
  rescue
    ArgumentError -> 0
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
