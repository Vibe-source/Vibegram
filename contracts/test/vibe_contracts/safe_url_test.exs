defmodule VibeContracts.SafeURLTest do
  use ExUnit.Case, async: true
  alias VibeContracts.SafeURL

  # Host literals resolve locally (no DNS/network needed).
  @blocked_urls [
    {"loopback v4", "http://127.0.0.1/"},
    {"loopback v6", "http://[::1]/"},
    {"private 10/8", "http://10.1.2.3/"},
    {"private 172.16/12", "http://172.16.5.5/"},
    {"private 192.168/16", "http://192.168.1.5/"},
    {"link-local v4", "http://169.254.1.1/"},
    {"cloud metadata", "http://169.254.169.254/latest/meta-data/"},
    {"CGNAT 100.64/10", "http://100.64.0.1/"},
    {"this-network 0/8", "http://0.0.0.1/"},
    {"ULA v6 (fc00::/7)", "http://[fc00::1]/"},
    {"link-local v6 (fe80::/10)", "http://[fe80::1]/"},
    {"IPv4-mapped v6 loopback", "http://[::ffff:127.0.0.1]/"},
    {"IPv4-mapped v6 private", "http://[::ffff:10.0.0.1]/"}
  ]

  for {label, url} <- @blocked_urls do
    test "blocks #{label}" do
      assert {:error, :blocked_address} = SafeURL.validate(unquote(url))
    end
  end

  test "allows a public IPv4 address" do
    assert {:ok, %URI{host: "8.8.8.8"}} = SafeURL.validate("http://8.8.8.8/")
  end

  test "rejects a non-http(s) scheme" do
    assert {:error, :invalid_scheme} = SafeURL.validate("ftp://example.com/")
    assert {:error, :invalid_scheme} = SafeURL.validate("file:///etc/passwd")
  end

  test "rejects a missing or empty host" do
    assert {:error, :invalid_scheme} = SafeURL.validate("not-a-url-at-all")
    assert {:error, :missing_host} = SafeURL.validate("http:///no-host")
  end

  test "rejects non-binary input" do
    assert {:error, :invalid_url} = SafeURL.validate(nil)
    assert {:error, :invalid_url} = SafeURL.validate(123)
  end
end
