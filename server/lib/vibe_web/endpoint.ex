defmodule VibeWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :vibe

  # JSON/urlencoded cap.
  @max_json_body_bytes (case Integer.parse(System.get_env("MAX_JSON_BODY_BYTES") || "8000000") do
                          {value, _} when value > 0 -> value
                          _ -> 8_000_000
                        end)

  # Content-Length sanity ceiling across all routes.
  @max_upload_body_bytes (case Integer.parse(System.get_env("MAX_UPLOAD_BYTES") || "99000000") do
                             {value, _} when value > 0 -> value
                             _ -> 99_000_000
                           end)

  # The session will be stored in the cookie and signed.
  @session_options [
    store: :cookie,
    key: "_vibe_key",
    signing_salt: "VA520x4+"
  ]

  socket("/socket", VibeWeb.UserSocket,
    websocket: [
      # Phoenix only forwards headers whose names start with "x-".
      connect_info: [:x_headers]
    ],
    longpoll: false
  )

  # Agent bridge daemon (the user's computer) connects here.
  socket("/agent-bridge", VibeWeb.AgentBridgeSocket,
    websocket: [connect_info: [:x_headers]],
    longpoll: false
  )

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # Serve at "/" the static files from "priv/static" directory.
  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
    plug(Phoenix.Ecto.CheckRepoStatus, otp_app: :vibe)
  end

  plug(Plug.Static,
    at: "/",
    from: if(code_reloading?, do: :vibe, else: "priv/static"),
    gzip: false,
    only: VibeWeb.static_paths()
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(VibeWeb.Plugs.BodyLimit, max_bytes: @max_upload_body_bytes)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    length: @max_json_body_bytes,
    json_decoder: Phoenix.json_library(),
    body_reader: {VibeWeb.Plugs.RawBodyReader, :read_body, []}
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)

  cors_origins =
    case System.get_env("CORS_ORIGINS") do
      nil ->
        [
          "http://localhost:3000",
          "http://localhost:5173",
          "https://localhost:5173",
          "https://vibe-io-nine.vercel.app",
          ~r/https?:\/\/.*railway\.app$/,
          ~r/https?:\/\/.*ngrok\.io$/,
          ~r/https?:\/\/.*ngrok-free\.app$/
        ]

      raw ->
        raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end

  plug(CORSPlug,
    origin: cors_origins,
    headers: [
      "Authorization",
      "Content-Type",
      "Accept",
      "Origin",
      "User-Agent",
      "DNT",
      "Cache-Control",
      "X-Mx-ReqToken",
      "Keep-Alive",
      "X-Requested-With",
      "If-Modified-Since",
      "ngrok-skip-browser-warning",
      "x-vibe-auth",
      "x-vibe-bridge-token"
    ]
  )

  plug(VibeWeb.Plugs.SecurityHeaders)
  plug(VibeWeb.Router)

  @doc """
  Production Ecto SSL options from env-style inputs.
  """
  def db_ssl_opts(verify_env, cacert_ders) do
    verify =
      case verify_env do
        nil -> nil
        value when is_binary(value) -> String.downcase(String.trim(value))
        _ -> nil
      end

    case verify do
      "none" ->
        [verify: :verify_none]

      _ ->
        if is_list(cacert_ders) and cacert_ders != [] do
          [verify: :verify_peer, cacerts: cacert_ders]
        else
          [verify: :verify_none]
        end
    end
  end
end
