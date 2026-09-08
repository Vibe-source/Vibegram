defmodule VibeWeb.MusicController do
  @moduledoc """
  Music streaming controller.
  """
  use VibeWeb, :controller

  require Logger

  alias Vibe.AI.Tools.YtDlp
  alias Vibe.MusicCache
  alias Vibe.MusicCacheFill
  alias Vibe.Storage
  alias Vibe.Repo
  import Ecto.Query

  # Temp directory for downloads before uploading to Supabase
  @temp_dir "/tmp/vibe_audio_downloads"

  @doc """
  Stream audio for a given video_id.
  """
  def stream(conn, %{"video_id" => video_id}) do
    Logger.info("[MusicController] Stream request for: #{video_id}")

    case get_cached_url(video_id) do
      {:ok, url} ->
        Logger.info("[MusicController] Redirecting to cached: #{video_id}")
        redirect(conn, external: url)

      :not_cached ->
        case download_and_upload(video_id) do
          {:ok, url} ->
            Logger.info("[MusicController] Cached and redirecting: #{video_id}")
            redirect(conn, external: url)

          {:error, reason} ->
            Logger.error("[MusicController] Download failed: #{reason}")

            case get_direct_stream_url(video_id) do
              {:ok, direct_url} ->
                Logger.info("[MusicController] Falling back to direct stream: #{video_id}")
                redirect(conn, external: direct_url)

              {:error, _} ->
                conn
                |> put_status(500)
                |> json(%{error: "Failed to stream audio", reason: reason})
            end
        end
    end
  end

  @doc """
  Check if audio is cached and get info.
  """
  def info(conn, %{"video_id" => video_id}) do
    case get_cached_url(video_id) do
      {:ok, url} ->
        json(conn, %{
          video_id: video_id,
          cached: true,
          stream_url: url
        })

      :not_cached ->
        case download_and_upload(video_id) do
          {:ok, url} ->
            json(conn, %{
              video_id: video_id,
              cached: true,
              stream_url: url
            })

          {:error, reason} ->
            Logger.warning("[MusicController] Info download failed: #{reason}")
            case get_direct_stream_url(video_id) do
              {:ok, direct_url} ->
                json(conn, %{
                  video_id: video_id,
                  cached: false,
                  stream_url: direct_url
                })

              {:error, _} ->
                conn
                |> put_status(500)
                |> json(%{error: "Failed to get stream URL", reason: reason})
            end
        end
    end
  end

  # Get direct stream URL without downloading (for fallback).
  defp get_direct_stream_url(video_id) do
    MusicCacheFill.fill("direct:" <> video_id, fn -> do_get_direct_stream_url(video_id) end)
  end

  defp do_get_direct_stream_url(video_id) do
    source = resolve_source_url(video_id)

    if is_binary(source) and String.starts_with?(source, "sc_") do
      Logger.error(
        "[MusicController] No webpage_url for #{video_id}; cannot extract a direct stream"
      )

      {:error, "Missing SoundCloud source URL in cache"}
    else
      case YtDlp.get_stream_url(source) do
        {:ok, %{stream_url: url}} when not is_nil(url) and url != "" ->
          {:ok, url}

        {:ok, track} when is_map(track) ->
          url = track[:stream_url] || track[:preview_url] || track["stream_url"] || track["url"]

          if is_binary(url) and url != "" do
            {:ok, url}
          else
            {:error, "No stream URL available"}
          end

        _ ->
          {:error, "No stream URL available"}
      end
    end
  end

  # Private functions

  defp get_cached_url(video_id) do
    case MusicCache.get_by_video_id(video_id) do
      %MusicCache{cached_file_path: url} when is_binary(url) and url != "" ->
        {:ok, Storage.rewrite_public_url(url)}

      %MusicCache{stream_url: url} = entry
      when is_binary(url) and url != "" ->
        if MusicCache.stream_url_fresh?(entry) and not client_unfetchable_stream_url?(url) do
          {:ok, url}
        else
          :not_cached
        end

      _ ->
        :not_cached
    end
  end

  # SoundCloud (and any HLS) URLs are session/CDN-bound and 403 for the.
  defp client_unfetchable_stream_url?(url) when is_binary(url) do
    lower = String.downcase(url)

    String.contains?(lower, ".m3u8") or
      String.contains?(lower, "soundcloud.cloud") or
      String.contains?(lower, "media-streaming")
  end

  defp client_unfetchable_stream_url?(_), do: false

  defp resolve_source_url(video_id) do
    case MusicCache.get_by_video_id(video_id) do
      %MusicCache{external_links: links, source: source, query: query} when is_map(links) ->
        resolved =
          YtDlp.download_url_for_track_id(video_id, links: stringify_map(links), source: source)

        if is_binary(resolved) and String.starts_with?(resolved, "sc_") and
             is_binary(query) and YtDlp.music_page_url?(query) do
          query
        else
          resolved
        end

      %MusicCache{source: source, query: query} ->
        resolved = YtDlp.download_url_for_track_id(video_id, source: source)

        if is_binary(resolved) and String.starts_with?(resolved, "sc_") and
             is_binary(query) and YtDlp.music_page_url?(query) do
          query
        else
          resolved
        end

      _ ->
        YtDlp.download_url_for_track_id(video_id)
    end
  end

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_map(_), do: %{}

  defp download_and_upload(video_id) do
    MusicCacheFill.fill(video_id, fn ->
      case get_cached_url(video_id) do
        {:ok, url} ->
          Logger.info("[MusicController] Cache filled while queued: #{video_id}")
          {:ok, url}

        :not_cached ->
          do_fill(video_id)
      end
    end)
  end

  defp do_fill(video_id) do
    Logger.info("[MusicController] Downloading audio for: #{video_id}")

    File.mkdir_p!(@temp_dir)

    safe_id = String.replace(video_id, ~r/[^a-zA-Z0-9_-]/, "_")
    temp_path = Path.join(@temp_dir, "#{safe_id}.m4a")
    remote_path = "#{safe_id}.m4a"

    source_url = resolve_source_url(video_id)

    if source_url == video_id and String.starts_with?(video_id, "sc_") do
      Logger.error(
        "[MusicController] SoundCloud track #{video_id} has no cached webpage_url — resolve via search_music first"
      )

      {:error, "Missing SoundCloud source URL in cache"}
    else
      do_download_and_upload(video_id, source_url, temp_path, remote_path)
    end
  end

  defp do_download_and_upload(video_id, source_url, temp_path, remote_path) do
    if is_binary(source_url) and String.starts_with?(source_url, "http") and
         match?({:error, _}, YtDlp.safe_media_url(source_url)) do
      Logger.warning("[MusicController] blocked unsafe download source for #{video_id}")
      {:error, "unsupported_or_unsafe_url"}
    else
      do_download_and_upload_checked(video_id, source_url, temp_path, remote_path)
    end
  end

  defp do_download_and_upload_checked(video_id, source_url, temp_path, remote_path) do
    Logger.info("[MusicController] yt-dlp download source=#{source_url}")

    args =
      [
        "-f",
        "ba/b",
        "-x",
        "--audio-format",
        "m4a",
        "--no-playlist",
        "--no-warnings",
        "-o",
        temp_path
      ] ++
        YtDlp.hardening_args() ++
        [
          "--",
          source_url
        ]

    result =
      case YtDlp.run_cmd(args, timeout: 120_000) do
        {:ok, _output} ->
          path =
            cond do
              File.exists?(temp_path) ->
                temp_path

              true ->
                Path.wildcard(temp_path <> "*") |> Enum.sort() |> List.last()
            end

          case path do
            nil ->
              {:error, "Download produced no file"}

            path ->
              case File.stat(path) do
                {:ok, stat} ->
                  case Storage.upload(path, remote_path) do
                    {:ok, public_url} ->
                      save_to_database(video_id, public_url, stat.size)
                      File.rm(path)
                      {:ok, public_url}

                    {:error, reason} ->
                      Logger.error("[MusicController] Supabase upload failed: #{reason}")
                      {:error, "Supabase upload failed: #{reason}"}
                  end

                {:error, reason} ->
                  {:error, "Could not stat file: #{inspect(reason)}"}
              end
          end

        {:error, reason} ->
          {:error, reason}
      end

    File.rm(temp_path)
    Path.wildcard(temp_path <> "*") |> Enum.each(&File.rm/1)

    result
  end

  defp save_to_database(video_id, url, size) do
    now = DateTime.utc_now()

    case MusicCache.get_by_video_id(video_id) do
      nil ->
        %MusicCache{}
        |> Ecto.Changeset.cast(
          %{
            video_id: video_id,
            title: video_id,
            query: video_id,
            query_hash: hash_string(video_id),
            cached_file_path: url,
            file_size_bytes: size,
            cached_at: now,
            stream_expires_at: nil
          },
          [
            :video_id,
            :title,
            :query,
            :query_hash,
            :cached_file_path,
            :file_size_bytes,
            :cached_at,
            :stream_expires_at
          ]
        )
        |> Repo.insert()
        |> log_result("Created")

      entry ->
        entry
        |> Ecto.Changeset.cast(
          %{
            cached_file_path: url,
            file_size_bytes: size,
            cached_at: now,
            stream_expires_at: nil
          },
          [:cached_file_path, :file_size_bytes, :cached_at, :stream_expires_at]
        )
        |> Repo.update()
        |> log_result("Updated")
    end
  end

  defp hash_string(str) do
    :crypto.hash(:sha256, str)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp log_result({:ok, _}, action), do: Logger.info("[MusicController] #{action} cache entry")

  defp log_result({:error, changeset}, action),
    do: Logger.error("[MusicController] Failed to #{action}: #{inspect(changeset.errors)}")
end
