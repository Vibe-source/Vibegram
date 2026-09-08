defmodule Vibe.AI.TranscribeSecurityTest do
  use ExUnit.Case, async: true

  alias Vibe.AI.Transcribe

  test "voice transcription rejects non-public URLs before credentials or network access" do
    for url <- [
          "http://127.0.0.1:4000/",
          "http://10.0.0.5/",
          "http://172.16.0.1/",
          "http://192.168.1.1/",
          "http://169.254.169.254/latest/meta-data/",
          "http://100.64.0.1/",
          "http://[::1]/",
          "http://[::ffff:127.0.0.1]/",
          "http://[fd00::1]/",
          "http://[fe80::1]/"
        ] do
      assert {:error, :blocked_address} = Transcribe.transcribe_url(url),
             "transcription accepted #{url}"
    end
  end

  test "voice transcription rejects unsupported schemes and malformed inputs" do
    for url <- ["file:///etc/passwd", "ftp://127.0.0.1/audio", "data:audio/wav;base64,AAAA", ""] do
      assert {:error, :invalid_scheme} = Transcribe.transcribe_url(url)
    end

    assert {:error, :missing_host} = Transcribe.transcribe_url("https:///audio.m4a")

    for value <- [nil, false, 123, %{}, []] do
      assert {:error, :invalid_url} = Transcribe.transcribe_url(value)
    end
  end

  test "voice attachment fallback safely skips rejected URLs" do
    assert is_nil(Transcribe.voice_text(["http://127.0.0.1/", "file:///etc/passwd"]))
  end
end
