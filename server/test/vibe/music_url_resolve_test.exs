defmodule Vibe.MusicUrlResolveTest do
  use ExUnit.Case, async: true

  alias Vibe.AI.Tools.Music
  alias Vibe.AI.Tools.YtDlp
  alias Vibe.MusicCache

  test "music_page_url? detects SoundCloud and YouTube" do
    assert YtDlp.music_page_url?("https://soundcloud.com/artist/track-name")
    assert YtDlp.music_page_url?("https://on.soundcloud.com/abc123")
    assert YtDlp.music_page_url?("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    assert YtDlp.music_page_url?("https://youtu.be/dQw4w9WgXcQ")
    refute YtDlp.music_page_url?("taylor swift blank space")
    refute YtDlp.music_page_url?("not a url")
  end

  test "download_url_for_track_id prefers webpage_url for SoundCloud" do
    url =
      YtDlp.download_url_for_track_id("sc_12345",
        links: %{
          "webpage_url" => "https://soundcloud.com/a/b",
          "soundcloud" => "https://soundcloud.com/a/b"
        },
        source: "soundcloud"
      )

    assert url == "https://soundcloud.com/a/b"
  end

  test "download_url_for_track_id defaults YouTube watch URL" do
    assert YtDlp.download_url_for_track_id("dQw4w9WgXcQ") ==
             "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
  end

  test "safe_media_url rejects non-music and spoofed music hosts before yt-dlp runs" do
    assert {:error, :host_not_allowed} = YtDlp.safe_media_url("https://example.com/audio")

    assert {:error, :host_not_allowed} =
             YtDlp.safe_media_url("https://soundcloud.com.evil.test/track")

    assert {:error, :invalid_url} = YtDlp.safe_media_url("file:///etc/passwd")
  end

  test "search rejects empty params" do
    assert %{error: _} = Music.search(%{})
  end

  # yt-dlp reports SoundCloud durations as floats (e.g.
  test "coerce_seconds rounds float/string durations to integer" do
    assert MusicCache.coerce_seconds(269.485) == 269
    assert MusicCache.coerce_seconds("30.9") == 31
    assert MusicCache.coerce_seconds(42) == 42
    assert MusicCache.coerce_seconds(nil) == nil
    assert MusicCache.coerce_seconds(:bogus) == nil
  end
end
