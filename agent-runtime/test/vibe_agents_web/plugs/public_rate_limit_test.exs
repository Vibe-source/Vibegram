defmodule VibeAgentsWeb.Plugs.PublicRateLimitTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias VibeAgentsWeb.Plugs.PublicRateLimit

  @table :vibe_agents_public_rate_limit
  @max_requests 600

  setup do
    PublicRateLimit.init_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp call(opts) do
    :post
    |> conn("/v1/agents/someagent/invoke")
    |> Map.put(:remote_ip, Keyword.get(opts, :remote_ip, {172, 30, 0, 9}))
    |> put_forwarded(Keyword.get(opts, :forwarded_for))
    |> put_secret(Keyword.get(opts, :secret))
    |> PublicRateLimit.call([])
  end

  defp put_forwarded(conn, nil), do: conn
  defp put_forwarded(conn, value), do: put_req_header(conn, "x-forwarded-for", value)

  defp put_secret(conn, nil), do: conn
  defp put_secret(conn, value), do: put_req_header(conn, "x-vibe-agent-secret", value)

  defp drain(count, opts_fun) do
    Enum.each(1..count, fn i -> call(opts_fun.(i)) end)
  end

  test "the table outlives the request process that first touched it" do
    parent = self()
    spawn(fn -> send(parent, {:done, call(forwarded_for: "203.0.113.7")}) end)
    assert_receive {:done, %Plug.Conn{}}, 1_000

    assert :ets.whereis(@table) != :undefined
    assert :ets.lookup(@table, "ip:203.0.113.7") != []
  end

  test "a fresh secret per request does not buy a fresh window" do
    drain(@max_requests, fn i -> [forwarded_for: "203.0.113.7", secret: "s-#{i}"] end)

    conn = call(forwarded_for: "203.0.113.7", secret: "s-brand-new")
    assert conn.halted
    assert conn.status == 429
  end

  test "one secret over the cap does not limit the same IP under a different secret" do
    drain(@max_requests, fn _ -> [forwarded_for: "203.0.113.8", secret: "hot"] end)

    assert call(forwarded_for: "203.0.113.8", secret: "hot").status == 429
    assert call(forwarded_for: "203.0.113.9", secret: "cold").halted == false
  end

  test "the client IP comes from the trusted forwarded hop, not the proxy" do
    drain(@max_requests, fn _ -> [remote_ip: {172, 30, 0, 9}, forwarded_for: "203.0.113.10"] end)

    assert call(remote_ip: {172, 30, 0, 9}, forwarded_for: "203.0.113.10").status == 429

    other = call(remote_ip: {172, 30, 0, 9}, forwarded_for: "203.0.113.11")
    assert other.halted == false
  end

  test "a spoofed extra forwarded hop cannot open a fresh window" do
    drain(@max_requests, fn _ -> [forwarded_for: "203.0.113.12"] end)

    spoofed = call(forwarded_for: "1.2.3.4, 203.0.113.12")
    assert spoofed.status == 429
  end

  test "with no forwarded header the socket peer is used" do
    drain(@max_requests, fn _ -> [remote_ip: {198, 51, 100, 4}] end)

    assert call(remote_ip: {198, 51, 100, 4}).status == 429
    assert call(remote_ip: {198, 51, 100, 5}).halted == false
  end
end
