defmodule Vibe.Platforms.Providers.GitHubPublicBaseUrlTest do
  use ExUnit.Case, async: false

  alias Vibe.Platforms.Providers.GitHub

  @env_keys ~w[VIBE_PUBLIC_BASE_URL PUBLIC_BASE_URL PHX_HOST]

  setup do
    originals = Map.new(@env_keys, fn k -> {k, System.get_env(k)} end)

    for k <- @env_keys, do: System.delete_env(k)

    on_exit(fn ->
      for {k, v} <- originals do
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end
    end)

    :ok
  end

  test "prefers VIBE_PUBLIC_BASE_URL over PUBLIC_BASE_URL" do
    System.put_env("VIBE_PUBLIC_BASE_URL", "https://vibe-first.example")
    System.put_env("PUBLIC_BASE_URL", "https://public-second.example")

    assert GitHub.public_base_url() == "https://vibe-first.example"
  end

  test "falls back to PUBLIC_BASE_URL when VIBE_PUBLIC_BASE_URL is unset" do
    System.put_env("PUBLIC_BASE_URL", "https://api.vibegram.io")

    assert GitHub.public_base_url() == "https://api.vibegram.io"
  end

  test "falls back to PHX_HOST with https scheme when both public base vars are unset" do
    System.put_env("PHX_HOST", "api.example.test")

    assert GitHub.public_base_url() == "https://api.example.test"
  end

  test "defaults to api.vibegram.io when no env is set" do
    assert GitHub.public_base_url() == "https://api.vibegram.io"
  end

  test "normalizes trailing slash and bare host" do
    System.put_env("PUBLIC_BASE_URL", "https://api.vibegram.io/")
    assert GitHub.public_base_url() == "https://api.vibegram.io"

    System.delete_env("PUBLIC_BASE_URL")
    System.put_env("VIBE_PUBLIC_BASE_URL", "api.custom.host")
    assert GitHub.public_base_url() == "https://api.custom.host"
  end

  test "ignores blank PUBLIC_BASE_URL and continues fallback" do
    System.put_env("PUBLIC_BASE_URL", "   ")
    System.put_env("PHX_HOST", "from-phx.example")

    assert GitHub.public_base_url() == "https://from-phx.example"
  end
end
