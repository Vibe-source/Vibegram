defmodule Vibe.StoryCleaner do
  use GenServer
  require Logger

  # Run every hour
  @interval 60 * 60 * 1000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Logger.info("Starting StoryCleaner...")
    Process.send_after(self(), :cleanup, 60_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    Logger.info("Running scheduled story cleanup...")
    Vibe.Stories.cleanup_expired_stories()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @interval)
  end
end
