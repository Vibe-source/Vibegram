defmodule VibeAgents.Voice.Sessions do
  @moduledoc """
  ETS-backed registry of voice session metadata (agent/user/chat + agentProfile),
  keyed by session_id. Table :vibe_voice_sessions, record TTL 2h, swept periodically.
  Does not start the provider or the live Session GenServer — that happens on join.
  """
  use GenServer

  @table :vibe_voice_sessions
  @record_ttl_seconds 7_200
  @join_window_seconds 900
  @sweep_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec create(map()) :: {:ok, map()}
  def create(%{
        "agentId" => agent_id,
        "userId" => user_id,
        "chatId" => chat_id,
        "agentProfile" => agent_profile
      }) do
    session_id = Ecto.UUID.generate()
    now = System.system_time(:second)

    token =
      Phoenix.Token.sign(VibeAgentsWeb.Endpoint, "voice-session", %{
        sid: session_id,
        user_id: user_id,
        agent_id: agent_id
      })

    record = %{
      session_id: session_id,
      agent_id: agent_id,
      user_id: user_id,
      chat_id: chat_id,
      agent_profile: agent_profile,
      record_expires_at: now + @record_ttl_seconds
    }

    :ets.insert(@table, {session_id, record})

    {:ok,
     %{
       session_id: session_id,
       ws_url: ws_url(),
       token: token,
       expires_at: DateTime.from_unix!(now + @join_window_seconds)
     }}
  end

  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, record}] ->
        if record.record_expires_at > System.system_time(:second) do
          {:ok, record}
        else
          :ets.delete(@table, session_id)
          :error
        end

      [] ->
        :error
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)

    @table
    |> :ets.tab2list()
    |> Enum.each(fn {session_id, record} ->
      if record.record_expires_at <= now, do: :ets.delete(@table, session_id)
    end)

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp ws_url do
    base = Application.get_env(:vibe_agents, :public_url) || "ws://localhost:4100"
    String.trim_trailing(base, "/") <> "/v1/voice/socket/websocket"
  end
end
