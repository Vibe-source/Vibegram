defmodule VibeAgents.Voice.FakeProvider do
  @moduledoc false
  # Scriptable VibeAgents.Voice.Provider double.
  @behaviour VibeAgents.Voice.Provider

  use GenServer

  @impl VibeAgents.Voice.Provider
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl VibeAgents.Voice.Provider
  def send_audio(pid, pcm16), do: GenServer.cast(pid, {:call, :send_audio, [pcm16]})

  @impl VibeAgents.Voice.Provider
  def send_text(pid, text), do: GenServer.cast(pid, {:call, :send_text, [text]})

  @impl VibeAgents.Voice.Provider
  def send_image(pid, jpeg), do: GenServer.cast(pid, {:call, :send_image, [jpeg]})

  @impl VibeAgents.Voice.Provider
  def commit(pid), do: GenServer.cast(pid, {:call, :commit, []})

  @impl VibeAgents.Voice.Provider
  def interrupt(pid), do: GenServer.cast(pid, {:call, :interrupt, []})

  @impl VibeAgents.Voice.Provider
  def tool_result(pid, call_id, result), do: GenServer.cast(pid, {:call, :tool_result, [call_id, result]})

  @impl VibeAgents.Voice.Provider
  def stop(pid), do: GenServer.cast(pid, {:call, :stop, []})

  @doc "Test helper: push {:voice_provider, event} to this fake's owner."
  def emit(pid, event), do: GenServer.cast(pid, {:emit, event})

  @doc "Test helper: calls received so far, oldest first, as {function, args}."
  def get_calls(pid), do: GenServer.call(pid, :get_calls)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    if Keyword.get(opts, :auto_ready, true), do: send(self(), :announce_ready)
    {:ok, %{owner: owner, calls: []}}
  end

  @impl true
  def handle_cast({:call, fun, args}, state), do: {:noreply, %{state | calls: [{fun, args} | state.calls]}}
  def handle_cast({:emit, event}, state) do
    send(state.owner, {:voice_provider, event})
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

  @impl true
  def handle_info(:announce_ready, state) do
    send(state.owner, {:voice_provider, {:ready}})
    {:noreply, state}
  end
end
