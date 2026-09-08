defmodule VibeAgents.Voice.Provider do
  @moduledoc """
  Behaviour for a realtime speech provider (`VibeAgents.Voice.OpenAIRealtime` is the
  first adapter). All calls besides `start_link/1` are fire-and-forget; the provider
  reports back to its owner asynchronously via `{:voice_provider, event}` messages.

  `event` is one of:
    `{:ready}` | `{:transcript_user, text, final?}` | `{:transcript_agent, text, final?}`
    | `{:audio, pcm16_binary}` | `{:tool_call, call_id, name, input}`
    | `{:error, reason}` | `{:done}`

  See docs/agent-voice-v1.md §4 for the full contract.
  """

  @callback start_link(opts :: keyword()) :: GenServer.on_start()
  @callback send_audio(pid(), pcm16 :: binary()) :: :ok
  @callback send_text(pid(), text :: String.t()) :: :ok
  @callback send_image(pid(), jpeg :: binary()) :: :ok
  @callback commit(pid()) :: :ok
  @callback interrupt(pid()) :: :ok
  @callback tool_result(pid(), call_id :: String.t(), result :: term()) :: :ok
  @callback stop(pid()) :: :ok
end
