defmodule VibeAgentsWeb.Plugs.PublicRateLimit do
  @moduledoc "ETS sliding window for /v1/* provider ingress: 600/min per client IP, plus per secret hash. The secret is unverified here, so it may only add a bucket, never open a fresh one."
  import Plug.Conn
  require Logger

  @behaviour Plug
  @table :vibe_agents_public_rate_limit
  @window_ms 60_000
  @max_requests 600

  def init(opts), do: opts

  def call(conn, _opts) do
    init_table()

    if Enum.any?(identifiers(conn), &(check(&1) == :limited)) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("retry-after", "60")
      |> send_resp(429, Jason.encode!(%{"error" => "rate_limited"}))
      |> halt()
    else
      conn
    end
  end

  defp identifiers(conn) do
    ip_key = "ip:" <> forwarded_or_remote_ip(conn)

    case secret(conn) do
      nil -> [ip_key]
      secret -> [ip_key, "secret:" <> hash(secret)]
    end
  end

  defp secret(conn) do
    header = fn name -> conn |> get_req_header(name) |> List.first() end

    case header.("x-vibe-agent-secret") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        case header.("authorization") do
          "Bearer " <> token -> token
          _ -> nil
        end
    end
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp forwarded_or_remote_ip(conn) do
    hops = trusted_proxy_hops()
    chain = forwarded_chain(conn)

    cond do
      hops == 0 -> remote_ip(conn)
      length(chain) < hops -> remote_ip(conn)
      true -> Enum.at(chain, length(chain) - hops) || remote_ip(conn)
    end
  end

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

  defp remote_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp check(key) do
    now = System.system_time(:millisecond)
    window_start = now - @window_ms
    maybe_sweep(window_start)

    case :ets.lookup(@table, key) do
      [] ->
        :ets.insert(@table, {key, [now]})
        :ok

      [{^key, timestamps}] ->
        recent = Enum.filter(timestamps, &(&1 > window_start))

        if length(recent) >= @max_requests do
          :limited
        else
          :ets.insert(@table, {key, [now | recent]})
          :ok
        end
    end
  end

  defp maybe_sweep(window_start) do
    if :rand.uniform(200) == 1 do
      stale =
        :ets.foldl(
          fn {key, timestamps}, acc ->
            if Enum.all?(timestamps, &(&1 <= window_start)), do: [key | acc], else: acc
          end,
          [],
          @table
        )

      Enum.each(stale, &:ets.delete(@table, &1))
    end

    :ok
  end

  @doc "Creates the window table under the application process, so it outlives every request."
  def init_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
