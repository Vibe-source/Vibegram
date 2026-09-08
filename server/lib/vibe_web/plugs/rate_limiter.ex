defmodule VibeWeb.Plugs.RateLimiter do
  @moduledoc """
  Rate limiting plug.
  """
  import Plug.Conn
  require Logger

  @behaviour Plug

  # Default limits (can be overridden in opts)
  @default_limits %{
    # 10 attempts per minute for login/register
    auth: {10, 60_000},
    # 300 requests per minute for general API
    api: {300, 60_000},
    # 60 requests per minute for expensive authenticated ops
    strict: {60, 60_000},
    # 600 requests per minute for secret-backed agent ingress
    public_agent: {600, 60_000},
    # 10 per 5 minutes for AI media edits.
    ai_media: {10, 300_000}
  }

  def init(opts), do: opts

  def call(conn, opts) do
    limit_type = Keyword.get(opts, :type, :api)
    {max_requests, window_ms} = resolve_limits(limit_type)

    identifier = get_identifier(conn)
    bucket = request_bucket(conn.request_path)
    key = {limit_type, bucket, identifier.kind, identifier.value}

    case Vibe.RateLimit.backend().hit(key, max_requests, window_ms) do
      {:ok, remaining, reset_at_ms} ->
        maybe_log_request(
          conn,
          limit_type,
          identifier,
          bucket,
          remaining,
          max_requests,
          window_ms
        )

        attach_rate_limit_headers(conn, max_requests, remaining, reset_at_ms)

      {:error, retry_after_ms, reset_at_ms} ->
        retry_after_seconds = div(retry_after_ms, 1000) + 1
        :telemetry.execute([:vibe, :rate_limit, :blocked], %{count: 1}, %{type: limit_type})

        Logger.warning(
          "[RateLimiter] blocked request " <>
            "type=#{limit_type} method=#{conn.method} bucket=#{bucket} path=#{conn.request_path} " <>
            "identifier_kind=#{identifier.kind} identifier=#{identifier.fingerprint} " <>
            "limit=#{max_requests}/#{window_ms}ms retry_after=#{retry_after_seconds}s"
        )

        conn
        |> attach_rate_limit_headers(max_requests, 0, reset_at_ms)
        |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
        |> put_resp_content_type("application/json")
        |> send_resp(
          429,
          Jason.encode!(%{
            error: "Too many requests",
            retry_after: retry_after_seconds,
            message: "Please slow down. Try again in #{retry_after_seconds} seconds."
          })
        )
        |> halt()
    end
  end

  defp get_identifier(conn) do
    case conn.assigns[:current_user] do
      %Vibe.Accounts.User{id: user_id} ->
        identifier(:user, user_id)

      _ ->
        identifier(:ip, forwarded_or_remote_ip(conn))
    end
  end

  defp resolve_limits(limit_type) do
    {default_max_requests, default_window_ms} =
      Map.get(@default_limits, limit_type, {300, 60_000})

    env_prefix = limit_type |> Atom.to_string() |> String.upcase()

    {
      parse_positive_env("RATE_LIMIT_#{env_prefix}_MAX_REQUESTS", default_max_requests),
      parse_positive_env("RATE_LIMIT_#{env_prefix}_WINDOW_MS", default_window_ms)
    }
  end

  defp parse_positive_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      raw ->
        case Integer.parse(raw) do
          {value, _} when value > 0 -> value
          _ -> default
        end
    end
  end

  defp attach_rate_limit_headers(conn, max_requests, remaining, reset_at_ms) do
    conn
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(max_requests))
    |> put_resp_header("x-ratelimit-remaining", Integer.to_string(max(remaining, 0)))
    |> put_resp_header("x-ratelimit-reset", Integer.to_string(div(reset_at_ms, 1000)))
  end

  defp maybe_log_request(conn, limit_type, identifier, bucket, remaining, max_requests, window_ms) do
    if log_requests?(limit_type, remaining, max_requests) do
      Logger.info(
        "[RateLimiter] request " <>
          "type=#{limit_type} method=#{conn.method} bucket=#{bucket} path=#{conn.request_path} " <>
          "identifier_kind=#{identifier.kind} identifier=#{identifier.fingerprint} " <>
          "remaining=#{remaining} limit=#{max_requests}/#{window_ms}ms"
      )
    end
  end

  defp log_requests?(limit_type, remaining, max_requests) do
    case System.get_env("RATE_LIMIT_LOG_REQUESTS") do
      value when value in ["1", "true", "TRUE", "yes", "YES"] ->
        true

      _ ->
        limit_type in [:strict, :public_agent] and remaining <= max(div(max_requests, 10), 3)
    end
  end

  defp request_bucket("/api/agent/chat"), do: "/api/agent/chat"
  defp request_bucket("/api/agent/chat/sync"), do: "/api/agent/chat/sync"

  defp request_bucket(path) do
    cond do
      String.match?(path, ~r{^/api/agents/[^/]+/invoke$}) ->
        "/api/agents/:identifier/invoke"

      String.match?(path, ~r{^/api/agents/[^/]+/events$}) ->
        "/api/agents/:identifier/events"

      true ->
        path
    end
  end

  defp forwarded_or_remote_ip(conn) do
    hops = trusted_proxy_hops()
    chain = forwarded_chain(conn)

    cond do
      hops == 0 ->
        remote_ip(conn)

      length(chain) < hops ->
        remote_ip(conn)

      true ->
        Enum.at(chain, length(chain) - hops) || remote_ip(conn)
    end
  end

  defp remote_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp forwarded_chain(conn) do
    conn
    |> get_req_header("x-forwarded-for")
    |> Enum.join(",")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp trusted_proxy_hops do
    case System.get_env("TRUSTED_PROXY_HOPS") do
      nil ->
        1

      raw ->
        case Integer.parse(raw) do
          {n, _} when n >= 0 -> n
          _ -> 1
        end
    end
  end

  defp identifier(kind, value) do
    %{
      kind: kind,
      value: value,
      fingerprint: fingerprint(value)
    }
  end

  defp fingerprint(value) do
    value
    |> :erlang.iolist_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
