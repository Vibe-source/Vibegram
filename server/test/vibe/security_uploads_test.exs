defmodule Vibe.SecurityUploadsTest do
  @moduledoc "Upload classification is driven by magic bytes, never by the client's claim."

  use ExUnit.Case, async: true

  alias VibeWeb.MediaController

  defp tmp(bytes) do
    path = Path.join(System.tmp_dir!(), "vibe-upload-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "a real PNG declared as image stays an image" do
    path = tmp(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0>>)
    assert {:ok, "image", ".png"} = MediaController.classify("image", MediaController.sniff_type(path))
  end

  test "an SVG declared as an image is rejected" do
    path = tmp("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")
    assert {:error, :svg_not_allowed} = MediaController.classify("image", MediaController.sniff_type(path))
  end

  test "a body that does not match its declared type becomes a generic file" do
    path = tmp("#!/bin/sh\necho hi\n")
    assert {:ok, "file", nil} = MediaController.classify("image", MediaController.sniff_type(path))
    assert {:ok, "file", nil} = MediaController.classify("video", MediaController.sniff_type(path))
  end

  test "ISO-BMFF brands split into mp4, mov, m4a and heic" do
    mp4 = tmp(<<0, 0, 0, 24, "ftyp", "isom", 0, 0, 0, 0>>)
    mov = tmp(<<0, 0, 0, 24, "ftyp", "qt  ", 0, 0, 0, 0>>)
    m4a = tmp(<<0, 0, 0, 24, "ftyp", "M4A ", 0, 0, 0, 0>>)
    heic = tmp(<<0, 0, 0, 24, "ftyp", "heic", 0, 0, 0, 0>>)

    assert {:ok, "video", ".mp4"} = MediaController.classify("video", MediaController.sniff_type(mp4))
    assert {:ok, "video", ".mov"} = MediaController.classify("video", MediaController.sniff_type(mov))
    assert {:ok, "audio", ".m4a"} = MediaController.classify("audio", MediaController.sniff_type(m4a))
    assert {:ok, "image", ".heic"} = MediaController.classify("image", MediaController.sniff_type(heic))
  end

  test "a PDF is accepted regardless of the declared bucket" do
    path = tmp("%PDF-1.7\n%âãÏÓ\n")
    assert {:ok, "file", ".pdf"} = MediaController.classify("image", MediaController.sniff_type(path))
  end
end
