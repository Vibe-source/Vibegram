defmodule VibeWeb.EndpointDbSslTest do
  @moduledoc """
  Mirrors the DB SSL decision table in `config/runtime.exs`.
  """

  use ExUnit.Case, async: true

  alias VibeWeb.Endpoint

  # Stand-ins for DER blobs — this function only ever checks presence.
  @ders [<<1, 2, 3>>, <<4, 5, 6>>]

  describe "db_ssl_opts/2" do
    test "defaults to peer verification when CA material is available (unset env)" do
      assert Endpoint.db_ssl_opts(nil, @ders) == [verify: :verify_peer, cacerts: @ders]
      assert Endpoint.db_ssl_opts("", @ders) == [verify: :verify_peer, cacerts: @ders]
    end

    test "explicit DB_SSL_VERIFY=none opts out even when CA material exists" do
      assert Endpoint.db_ssl_opts("none", @ders) == [verify: :verify_none]
      assert Endpoint.db_ssl_opts("NONE", @ders) == [verify: :verify_none]
      assert Endpoint.db_ssl_opts("  none  ", []) == [verify: :verify_none]
    end

    test "peer verify when verify env is peer or other non-none value" do
      assert Endpoint.db_ssl_opts("peer", @ders) == [verify: :verify_peer, cacerts: @ders]
      assert Endpoint.db_ssl_opts("true", @ders) == [verify: :verify_peer, cacerts: @ders]
    end

    test "falls back to verify_none when no CA material is available" do
      assert Endpoint.db_ssl_opts(nil, nil) == [verify: :verify_none]
      assert Endpoint.db_ssl_opts("peer", nil) == [verify: :verify_none]
      assert Endpoint.db_ssl_opts(nil, []) == [verify: :verify_none]
    end
  end
end
