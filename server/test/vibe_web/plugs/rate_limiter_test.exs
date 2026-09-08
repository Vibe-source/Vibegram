defmodule VibeWeb.Plugs.RateLimiterTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias VibeWeb.Plugs.RateLimiter

  setup do
    _ = RateLimiter.init([])
    :ets.delete_all_objects(:rate_limiter)

    original_hops = System.get_env("TRUSTED_PROXY_HOPS")
    System.delete_env("TRUSTED_PROXY_HOPS")

    on_exit(fn ->
      :ets.delete_all_objects(:rate_limiter)

      if original_hops do
        System.put_env("TRUSTED_PROXY_HOPS", original_hops)
      else
        System.delete_env("TRUSTED_PROXY_HOPS")
      end
    end)
  end

  test "unverified credentials cannot select a fresh authentication quota" do
    for header <- ["authorization", "x-vibe-agent-secret", "x-vibe-integration-secret"] do
      :ets.delete_all_objects(:rate_limiter)

      for attempt <- 1..11 do
        result =
          :post
          |> conn("/api/login", "")
          |> put_req_header(header, "Bearer forged-#{attempt}")
          |> RateLimiter.call(type: :auth)

        if attempt <= 10 do
          refute result.halted
        else
          assert result.halted
          assert result.status == 429
        end
      end
    end
  end

  test "verified user identities retain separate quotas" do
    for attempt <- 1..11 do
      result =
        :post
        |> conn("/api/login", "")
        |> assign(:current_user, %Vibe.Accounts.User{id: "user-#{attempt}"})
        |> RateLimiter.call(type: :auth)

      refute result.halted
    end
  end

  test "uses trusted right-side X-Forwarded-For entry so spoofed prefixes do not bypass auth limit" do
    allowed =
      for i <- 1..10 do
        conn =
          :post
          |> conn("/api/login", "")
          |> Map.put(:remote_ip, {10, 0, 0, 5})
          |> put_req_header("x-forwarded-for", "198.51.100.#{i}, 203.0.113.9")
          |> RateLimiter.call(type: :auth)

        refute conn.halted
        get_resp_header(conn, "x-ratelimit-remaining") |> List.first()
      end

    assert List.last(allowed) == "0"

    blocked =
      :post
      |> conn("/api/login", "")
      |> Map.put(:remote_ip, {10, 0, 0, 5})
      |> put_req_header("x-forwarded-for", "198.51.100.250, 203.0.113.9")
      |> RateLimiter.call(type: :auth)

    assert blocked.halted
    assert blocked.status == 429
  end
end
