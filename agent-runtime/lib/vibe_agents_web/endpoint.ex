defmodule VibeAgentsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :vibe_agents

  @parser_length 2_000_000

  # Voice calls (docs/agent-voice-v1.md):
  socket("/v1/voice/socket", VibeAgentsWeb.VoiceSocket, websocket: true, longpoll: false)

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    length: @parser_length,
    json_decoder: Phoenix.json_library(),
    body_reader: {VibeAgentsWeb.Plugs.RawBodyReader, :read_body, []}
  )

  plug(Plug.Head)
  plug(VibeAgentsWeb.Router)
end
