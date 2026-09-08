defmodule VibeContracts.ServiceAuthTest do
  use ExUnit.Case, async: true
  alias VibeContracts.ServiceAuth

  @key String.duplicate("k", 32)

  # Unique per call so tests hitting the default ETS replay store never.
  defp unique_nonce, do: "nonce-#{System.unique_integer([:positive])}"

  test "a freshly signed request verifies ok" do
    nonce = unique_nonce()

    headers =
      ServiceAuth.sign(@key, "POST", "/internal/v1/runs", "{}",
        service: "core",
        timestamp: 1_700_000_000,
        nonce: nonce
      )

    assert %{
             "x-vibe-service" => "core",
             "x-vibe-timestamp" => "1700000000",
             "x-vibe-nonce" => ^nonce,
             "x-vibe-signature" => "v1=" <> _
           } = headers

    assert :ok =
             ServiceAuth.verify(@key, "POST", "/internal/v1/runs", "{}", headers,
               now: 1_700_000_000
             )
  end

  test "headers/5 signs identically to sign/5, just as a list of tuples" do
    nonce = unique_nonce()
    opts = [service: "core", timestamp: 1000, nonce: nonce]

    map = ServiceAuth.sign(@key, "GET", "/x", "", opts)
    list = ServiceAuth.headers(@key, "GET", "/x", "", opts)

    assert is_list(list)
    assert Enum.into(list, %{}) == map
  end

  test "a tampered body fails signature verification" do
    nonce = unique_nonce()

    headers =
      ServiceAuth.sign(@key, "POST", "/x", "original",
        service: "core",
        timestamp: 1000,
        nonce: nonce
      )

    assert {:error, :bad_signature} =
             ServiceAuth.verify(@key, "POST", "/x", "tampered", headers, now: 1000)
  end

  test "a swapped x-vibe-service is rejected even with an otherwise valid signature" do
    nonce = unique_nonce()

    headers =
      ServiceAuth.sign(@key, "POST", "/internal/v1/agent-events", "{}",
        service: "agent-runtime",
        timestamp: 1000,
        nonce: nonce
      )

    swapped = Map.put(headers, "x-vibe-service", "core")

    assert {:error, :bad_signature} =
             ServiceAuth.verify(@key, "POST", "/internal/v1/agent-events", "{}", swapped,
               now: 1000,
               allowed_services: ["core", "agent-runtime"]
             )
  end

  test "a stale timestamp is rejected outside tolerance, accepted at the edge" do
    nonce = unique_nonce()

    headers =
      ServiceAuth.sign(@key, "POST", "/x", "a", service: "core", timestamp: 1000, nonce: nonce)

    assert {:error, :stale_timestamp} =
             ServiceAuth.verify(@key, "POST", "/x", "a", headers, now: 1301)

    assert :ok = ServiceAuth.verify(@key, "POST", "/x", "a", headers, now: 1300)
  end

  test "a replayed nonce is rejected on the second verify via the default ETS store" do
    nonce = unique_nonce()

    headers =
      ServiceAuth.sign(@key, "POST", "/x", "a", service: "core", timestamp: 1000, nonce: nonce)

    assert :ok = ServiceAuth.verify(@key, "POST", "/x", "a", headers, now: 1000)

    assert {:error, :replayed_nonce} =
             ServiceAuth.verify(@key, "POST", "/x", "a", headers, now: 1000)
  end

  test "a custom nonce_seen? callback is honored instead of the default store" do
    nonce = unique_nonce()

    headers =
      ServiceAuth.sign(@key, "POST", "/x", "a", service: "core", timestamp: 1000, nonce: nonce)

    assert {:error, :replayed_nonce} =
             ServiceAuth.verify(@key, "POST", "/x", "a", headers,
               now: 1000,
               nonce_seen?: fn ^nonce -> true end
             )

    assert :ok =
             ServiceAuth.verify(@key, "POST", "/x", "a", headers,
               now: 1000,
               nonce_seen?: fn ^nonce -> false end
             )
  end

  test "an unknown x-vibe-service is rejected" do
    nonce = unique_nonce()

    headers =
      ServiceAuth.sign(@key, "POST", "/x", "a", service: "core", timestamp: 1000, nonce: nonce)

    bad = Map.put(headers, "x-vibe-service", "evil-service")

    assert {:error, :unknown_service} =
             ServiceAuth.verify(@key, "POST", "/x", "a", bad,
               now: 1000,
               nonce_seen?: fn _ -> false end
             )

    signed_as_evil =
      ServiceAuth.sign(@key, "POST", "/x", "a",
        service: "evil-service",
        timestamp: 1000,
        nonce: unique_nonce()
      )

    assert :ok =
             ServiceAuth.verify(@key, "POST", "/x", "a", signed_as_evil,
               now: 1000,
               nonce_seen?: fn _ -> false end,
               allowed_services: ["evil-service"]
             )
  end

  test "verification fails closed when the replay store is unavailable" do
    nonce = unique_nonce()

    headers =
      ServiceAuth.sign(@key, "POST", "/x", "a", service: "core", timestamp: 1000, nonce: nonce)

    assert {:error, :nonce_store_unavailable} =
             ServiceAuth.verify(@key, "POST", "/x", "a", headers,
               now: 1000,
               nonce_seen?: fn _ -> :unavailable end
             )
  end

  test "missing or incomplete headers are rejected" do
    assert {:error, :missing_headers} =
             ServiceAuth.verify(@key, "POST", "/x", "a", %{}, now: 1000)

    assert {:error, :missing_headers} =
             ServiceAuth.verify(@key, "POST", "/x", "a", %{"x-vibe-service" => "core"}, now: 1000)
  end

  test "verify accepts headers as a list of pairs, matched case-insensitively" do
    nonce = unique_nonce()

    list =
      ServiceAuth.headers(@key, "POST", "/x", "a", service: "core", timestamp: 1000, nonce: nonce)

    upcased = Enum.map(list, fn {k, v} -> {String.upcase(k), v} end)

    assert :ok = ServiceAuth.verify(@key, "POST", "/x", "a", upcased, now: 1000)
  end

  test "a weak key (< 32 bytes) is rejected by sign, headers, and verify" do
    short_key = "too-short"

    assert {:error, :weak_key} = ServiceAuth.sign(short_key, "GET", "/x", "", service: "core")
    assert {:error, :weak_key} = ServiceAuth.headers(short_key, "GET", "/x", "", service: "core")

    headers =
      ServiceAuth.sign(@key, "GET", "/x", "",
        service: "core",
        timestamp: 1000,
        nonce: unique_nonce()
      )

    assert {:error, :weak_key} =
             ServiceAuth.verify(short_key, "GET", "/x", "", headers, now: 1000)
  end

  test "secure_compare/2 is true only for identical, equal-length binaries" do
    assert ServiceAuth.secure_compare("abc123", "abc123")
    refute ServiceAuth.secure_compare("abc123", "abc124")
    refute ServiceAuth.secure_compare("abc", "abcd")
    refute ServiceAuth.secure_compare("abc", 123)
  end
end
