defmodule Vibe.LinksShareBaseTest do
  use ExUnit.Case, async: false

  alias Vibe.Links

  setup do
    original = System.get_env("VIBE_SHARE_BASE_URL")

    on_exit(fn ->
      if original,
        do: System.put_env("VIBE_SHARE_BASE_URL", original),
        else: System.delete_env("VIBE_SHARE_BASE_URL")
    end)

    :ok
  end

  test "uses VIBE_SHARE_BASE_URL when present" do
    System.put_env("VIBE_SHARE_BASE_URL", "https://vibegram.io")
    assert Links.share_base_url() == "https://vibegram.io"
    assert Links.handle_url("alice") == "https://vibegram.io/alice"
  end

  test "defaults to api.vibegram.io when VIBE_SHARE_BASE_URL is unset" do
    System.delete_env("VIBE_SHARE_BASE_URL")
    assert Links.default_share_base() == "https://api.vibegram.io"
    assert Links.share_base_url() == "https://api.vibegram.io"
  end

  test "treats blank VIBE_SHARE_BASE_URL as unset" do
    System.put_env("VIBE_SHARE_BASE_URL", "  ")
    assert Links.share_base_url() == "https://api.vibegram.io"
  end

  test "normalizes bare host share base" do
    System.put_env("VIBE_SHARE_BASE_URL", "share.example")
    assert Links.share_base_url() == "https://share.example"
  end
end
