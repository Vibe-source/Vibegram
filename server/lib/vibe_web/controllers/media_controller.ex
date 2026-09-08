defmodule VibeWeb.MediaController do
  @moduledoc """
  Controller for media file uploads (images, audio, video).
  Uploads files to Supabase Storage and returns public URLs.
  """
  use VibeWeb, :controller

  alias Vibe.Storage

  require Logger

  @max_image_bytes (case Integer.parse(System.get_env("MAX_IMAGE_BYTES") || "25000000") do
                       {value, _} when value > 0 -> value
                       _ -> 25_000_000
                     end)

  @max_video_bytes (case Integer.parse(System.get_env("MAX_VIDEO_BYTES") || "120000000") do
                       {value, _} when value > 0 -> value
                       _ -> 120_000_000
                     end)

  @max_audio_bytes (case Integer.parse(System.get_env("MAX_AUDIO_BYTES") || "50000000") do
                       {value, _} when value > 0 -> value
                       _ -> 50_000_000
                     end)

  @max_file_bytes (case Integer.parse(System.get_env("MAX_FILE_BYTES") || "60000000") do
                      {value, _} when value > 0 -> value
                      _ -> 60_000_000
                    end)

  @sniff_bytes 512
  @object_key_pattern ~r/\A[A-Za-z0-9_-]{32}(?:\.(?:m4a|mp3|mp4|webm|jpg|jpeg|png|gif|webp|heic|wav|mov|pdf|csv|txt|json|xlsx))?\z/

  @doc """
  Upload a media file.
  """
  def upload(conn, %{"file" => %Plug.Upload{} = upload} = params) do
    user_id = conn.assigns.current_user.id
    declared_type = params["type"] || detect_type(upload.content_type)

    case classify(declared_type, sniff_type(upload.path)) do
      {:error, :svg_not_allowed} ->
        conn |> put_status(:bad_request) |> json(%{error: "SVG images are not allowed"})

      {:ok, media_type, ext} ->
        do_upload(conn, upload, user_id, media_type, ext)
    end
  end

  def upload(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing file parameter. Use multipart form with 'file' field."})
  end

  def object(conn, %{"key" => key}) do
    if Regex.match?(@object_key_pattern, key) do
      case Vibe.R2Storage.get_presigned_url(key, bucket: :media) do
        {:ok, url} -> redirect(conn, external: url)
        {:error, reason} ->
          Logger.error("[MediaController] Object URL failed: #{reason}")
          conn |> put_status(:service_unavailable) |> json(%{error: "Media unavailable"})
      end
    else
      conn |> put_status(:bad_request) |> json(%{error: "Invalid media key"})
    end
  end

  defp do_upload(conn, upload, user_id, media_type, ext) do
    max_bytes = max_bytes_for(media_type)

    case File.stat(upload.path) do
      {:ok, %{size: size}} when size > max_bytes ->
        conn
        |> put_status(:request_entity_too_large)
        |> json(%{error: "File too large", max_size: max_bytes})

      {:ok, %{size: size}} ->
        Logger.info("[MediaController] Upload: #{upload.filename} (#{size} bytes) type=#{media_type}")

        timestamp = System.system_time(:millisecond)
        random = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
        remote_path = "#{user_id}/#{timestamp}_#{random}#{ext || ""}"

        case Storage.upload(upload.path, remote_path, bucket: :media) do
          {:ok, public_url} ->
            Logger.info("[MediaController] Uploaded to: #{public_url}")
            durable_url = Storage.rewrite_public_url(public_url)
            json(conn, %{url: download_url(durable_url, ext), size: size, type: media_type})

          {:error, reason} ->
            Logger.error("[MediaController] Upload failed: #{reason}")
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Upload failed", reason: reason})
        end

      {:error, reason} ->
        Logger.error("[MediaController] Cannot stat file: #{inspect(reason)}")
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid file"})
    end
  end

  defp max_bytes_for("image"), do: @max_image_bytes
  defp max_bytes_for("video"), do: @max_video_bytes
  defp max_bytes_for("audio"), do: @max_audio_bytes
  defp max_bytes_for(_), do: @max_file_bytes

  defp download_url(url, nil) do
    if String.contains?(url, "?"), do: url <> "&download", else: url <> "?download"
  end

  defp download_url(url, _ext), do: url

  def classify("image", :svg), do: {:error, :svg_not_allowed}
  def classify("image", :jpeg), do: {:ok, "image", ".jpg"}
  def classify("image", :png), do: {:ok, "image", ".png"}
  def classify("image", :gif), do: {:ok, "image", ".gif"}
  def classify("image", :webp), do: {:ok, "image", ".webp"}
  def classify("image", :heic), do: {:ok, "image", ".heic"}
  def classify("video", :mp4), do: {:ok, "video", ".mp4"}
  def classify("video", :mov), do: {:ok, "video", ".mov"}
  def classify("audio", :mp3), do: {:ok, "audio", ".mp3"}
  def classify("audio", :m4a), do: {:ok, "audio", ".m4a"}
  def classify("audio", :ogg), do: {:ok, "audio", ".ogg"}
  def classify("audio", :wav), do: {:ok, "audio", ".wav"}
  def classify(_declared, :pdf), do: {:ok, "file", ".pdf"}
  def classify(_declared, _sniffed), do: {:ok, "file", nil}

  defp detect_type(content_type) when is_binary(content_type) do
    cond do
      String.starts_with?(content_type, "image/") -> "image"
      String.starts_with?(content_type, "audio/") -> "audio"
      String.starts_with?(content_type, "video/") -> "video"
      true -> "file"
    end
  end

  defp detect_type(_), do: "file"

  @doc false
  def sniff_type(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        head =
          case IO.binread(io, @sniff_bytes) do
            data when is_binary(data) -> data
            _ -> <<>>
          end

        File.close(io)
        sniff_head(head)

      {:error, _} ->
        :unknown
    end
  end

  defp sniff_head(<<0xFF, 0xD8, 0xFF, _::binary>>), do: :jpeg
  defp sniff_head(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: :png
  defp sniff_head(<<"GIF87a", _::binary>>), do: :gif
  defp sniff_head(<<"GIF89a", _::binary>>), do: :gif
  defp sniff_head(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: :webp
  defp sniff_head(<<"RIFF", _::binary-size(4), "WAVE", _::binary>>), do: :wav
  defp sniff_head(<<_::binary-size(4), "ftyp", brand::binary-size(4), _::binary>>), do: iso_bmff_kind(brand)
  defp sniff_head(<<"ID3", _::binary>>), do: :mp3
  defp sniff_head(<<0xFF, b, _::binary>>) when b >= 0xE0, do: :mp3
  defp sniff_head(<<"OggS", _::binary>>), do: :ogg
  defp sniff_head(<<"%PDF-", _::binary>>), do: :pdf

  defp sniff_head(head) do
    if String.valid?(head) and String.contains?(String.downcase(head), "<svg") do
      :svg
    else
      :unknown
    end
  end

  defp iso_bmff_kind(brand) when brand in ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"],
    do: :heic

  defp iso_bmff_kind(brand) when brand in ["M4A ", "M4B ", "M4P "], do: :m4a
  defp iso_bmff_kind("qt  "), do: :mov
  defp iso_bmff_kind(_), do: :mp4
end
