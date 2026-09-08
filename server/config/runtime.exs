import Config

if System.get_env("PHX_SERVER") do
  config :vibe, VibeWeb.Endpoint, server: true
end

if config_env() == :prod do
  media_cdn_base_url = System.get_env("MEDIA_CDN_BASE_URL")

  # Support DATABASE_URL directly.
  database_url = System.get_env("DATABASE_URL")

  database_url =
    if is_nil(database_url) do
      supabase_url = System.get_env("SUPABASE_URL")
      supabase_db_password = System.get_env("SUPABASE_DB_PASSWORD")

      if supabase_url && supabase_db_password do
        case Regex.run(~r/https?:\/\/([^.]+)\.supabase\.co/, supabase_url) do
          [_, project_ref] ->
            region = System.get_env("SUPABASE_REGION") || "us-east-1"

            "postgresql://postgres.#{project_ref}:#{URI.encode_www_form(supabase_db_password)}@aws-0-#{region}.pooler.supabase.com:6543/postgres"

          _ ->
            nil
        end
      end
    else
      database_url
    end

  # Fallback if still nil
  database_url =
    if is_nil(database_url) do
      IO.warn("""
      Environment variable DATABASE_URL is missing.
      Application will start but Database operations will fail.
      Set DATABASE_URL or SUPABASE_* vars to fix.
      """)

      "postgres://user:pass@localhost:5432/db_missing"
    else
      database_url
    end

  # Store Supabase credentials for API access (Storage, etc.)
  config :vibe, :supabase,
    url: System.get_env("SUPABASE_URL"),
    key: System.get_env("SUPABASE_KEY"),
    service_key: System.get_env("SUPABASE_SERVICE_KEY"),
    media_cdn_base_url: media_cdn_base_url,
    # Optional:
    bucket: System.get_env("SUPABASE_BUCKET"),
    media_bucket: System.get_env("SUPABASE_MEDIA_BUCKET"),
    music_bucket: System.get_env("SUPABASE_MUSIC_BUCKET")

  # Cloudflare R2 credentials (additive path alongside Supabase.
  config :vibe, :r2,
    account_id: System.get_env("R2_ACCOUNT_ID"),
    access_key_id: System.get_env("R2_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("R2_SECRET_ACCESS_KEY"),
    bucket: System.get_env("R2_BUCKET"),
    public_base_url: System.get_env("R2_PUBLIC_BASE_URL")

  # Lemon Squeezy configuration for payments
  config :vibe, :lemon_squeezy,
    api_key: System.get_env("LEMON_SQUEEZY_API_KEY"),
    store_id: System.get_env("LEMON_SQUEEZY_STORE_ID"),
    webhook_secret: System.get_env("LEMON_SQUEEZY_WEBHOOK_SECRET")

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ["true", "1"], do: [:inet6], else: []

  db_ssl_verify = System.get_env("DB_SSL_VERIFY")
  db_cacertfile_env = System.get_env("DB_CACERTFILE")

  default_cacertfile =
    Enum.find(
      [
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/ssl/cert.pem"
      ],
      &File.exists?/1
    )

  db_cacertfile = db_cacertfile_env || default_cacertfile

  db_ssl_verify_norm =
    case db_ssl_verify do
      nil -> nil
      value when is_binary(value) -> String.downcase(String.trim(value))
      _ -> nil
    end

  load_pem_ders = fn
    path when is_binary(path) ->
      case File.read(path) do
        {:ok, pem} -> for {:Certificate, der, _} <- :public_key.pem_decode(pem), do: der
        _ -> []
      end

    _ ->
      []
  end

  supabase_root_candidates =
    [
      try do
        Path.join(:code.priv_dir(:vibe), "certs/supabase-root-2021.crt")
      rescue
        _ -> nil
      end,
      "/app/certs/supabase-root-2021.crt",
      Path.join(File.cwd!(), "priv/certs/supabase-root-2021.crt")
    ]
    |> Enum.filter(&(is_binary(&1) and File.exists?(&1)))

  supabase_root_ders =
    supabase_root_candidates |> Enum.take(1) |> Enum.flat_map(load_pem_ders)

  if supabase_root_ders == [] and db_ssl_verify_norm != "none" do
    IO.warn(
      "Supabase root CA not found in any known location. The pooler chains to a " <>
        "private root, so verify_peer against a public bundle will fail with " <>
        "unknown_ca and the release will not start."
    )
  end

  db_cacert_ders = supabase_root_ders ++ load_pem_ders.(db_cacertfile)

  ssl_opts =
    case db_ssl_verify_norm do
      "none" ->
        [verify: :verify_none]

      _ ->
        if db_cacert_ders != [] do
          [verify: :verify_peer, cacerts: db_cacert_ders]
        else
          IO.warn(
            "DB SSL peer verification requested (or defaulted) but no CA bundle found; " <>
              "falling back to verify_none. Set DB_CACERTFILE or DB_SSL_VERIFY=none explicitly."
          )

          [verify: :verify_none]
        end
    end

  db_statement_timeout_ms = System.get_env("DB_STATEMENT_TIMEOUT_MS") || "30000"

  db_ssl? =
    case System.get_env("DB_SSL") do
      value when is_binary(value) ->
        String.downcase(String.trim(value)) not in ["false", "0", "off", "disable", "disabled"]

      _ ->
        true
    end

  config :vibe, Vibe.Repo,
    ssl: if(db_ssl?, do: ssl_opts, else: false),
    prepare: :unnamed,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "20"),
    queue_target: 5000,
    queue_interval: 1000,
    timeout: 30_000,
    connect_timeout: 30_000,
    handshake_timeout: 30_000,
    idle_interval: 10_000,
    parameters: [statement_timeout: db_statement_timeout_ms, application_name: "vibe-core"],
    socket_options: maybe_ipv6

  config :vibe, :agent_gateway,
    url: System.get_env("VIBE_AGENT_RUNTIME_URL"),
    hmac_key: System.get_env("VIBE_INTERNAL_HMAC_KEY"),
    execution_mode: System.get_env("VIBE_AGENT_EXECUTION_MODE"),
    kill_switch: System.get_env("VIBE_AI_KILL_SWITCH") in ["1", "true", "TRUE"]

  config :vibe, :valkey_url, System.get_env("VALKEY_URL")
  config :vibe, :rate_limit_backend, System.get_env("RATE_LIMIT_BACKEND") || "ets"
  config :vibe, :cluster_strategy, System.get_env("CLUSTER_STRATEGY") || "none"
  config :vibe, :metrics_port, String.to_integer(System.get_env("METRICS_PORT") || "9568")

  config :vibe, :agent_credits, %{
    "free" => String.to_integer(System.get_env("AGENT_CREDITS_FREE_CENTS") || "100"),
    "bronze" => String.to_integer(System.get_env("AGENT_CREDITS_BRONZE_CENTS") || "500"),
    "silver" => String.to_integer(System.get_env("AGENT_CREDITS_SILVER_CENTS") || "2000"),
    "gold" => String.to_integer(System.get_env("AGENT_CREDITS_GOLD_CENTS") || "10000")
  }

  config :vibe,
         :agent_routines_max_per_owner,
         String.to_integer(System.get_env("AGENT_ROUTINES_MAX_PER_OWNER") || "20")

  config :vibe,
         :agent_routine_min_minutes,
         String.to_integer(System.get_env("AGENT_ROUTINE_MIN_MINUTES") || "15")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  check_origin =
    case System.get_env("PHX_CHECK_ORIGIN") do
      nil ->
        ["https://" <> host, "https://vibe-io-nine.vercel.app"]

      "false" ->
        false

      raw ->
        raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end

  ranch_max_connections =
    case System.get_env("RANCH_MAX_CONNECTIONS") do
      nil -> 65_536
      "infinity" -> :infinity
      raw -> String.to_integer(raw)
    end

  config :vibe, VibeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port,
      transport_options: [max_connections: ranch_max_connections, num_acceptors: 100]
    ],
    check_origin: check_origin,
    secret_key_base: secret_key_base
end
