defmodule Vibe.SupabaseStorage do
  @moduledoc """
  Supabase Storage client for uploading and managing files.
  """

  require Logger

  @default_music_bucket "music-cache"
  @default_media_bucket "chat-media"
  @public_object_marker "/storage/v1/object/public/"

  defp sanitize_token(nil), do: nil

  defp sanitize_token(token) when is_binary(token) do
    token
    |> String.trim()
    |> String.trim_leading("Bearer ")
    |> String.trim()
  end

  defp jwt_compact?(token) when is_binary(token) do
    case String.split(token, ".", parts: 4) do
      [_h, _p, _s] -> true
      _ -> false
    end
  end

  defp build_auth_headers(config, extra_headers \\ []) do
    service_key = sanitize_token(config.service_key)
    api_key = sanitize_token(config.key) || service_key

    headers =
      []
      |> maybe_put_header("Authorization", service_key && "Bearer #{service_key}")
      |> maybe_put_header("apikey", api_key)
      |> Kernel.++(extra_headers)

    {headers, service_key}
  end

  defp maybe_put_header(headers, _k, nil), do: headers
  defp maybe_put_header(headers, _k, ""), do: headers
  defp maybe_put_header(headers, k, v), do: [{k, v} | headers]

  defp resolve_bucket(config, :music),
    do: config.music_bucket || config.bucket || @default_music_bucket

  defp resolve_bucket(config, :media),
    do: config.media_bucket || config.bucket || @default_media_bucket

  defp resolve_bucket(_config, bucket) when is_binary(bucket) and bucket != "", do: bucket
  defp resolve_bucket(config, _), do: resolve_bucket(config, :music)

  @doc """
  Upload a file to Supabase Storage.
  Returns {:ok, public_url} or {:error, reason}
  """
  def upload(local_path, remote_path), do: upload(local_path, remote_path, [])

  def upload(local_path, remote_path, opts) when is_list(opts) do
    config = get_config()

    unless config.url && config.service_key && config.service_key != "" do
      Logger.warning("[SupabaseStorage] Missing config, skipping upload")
      {:error, "Supabase not configured"}
    else
      bucket = resolve_bucket(config, Keyword.get(opts, :bucket, :music))

      {headers, service_key} =
        build_auth_headers(config, [
          {"Content-Type", get_content_type(remote_path)},
          {"x-upsert", "true"}
        ])

      if is_binary(service_key) and service_key != "" and not jwt_compact?(service_key) do
        Logger.error(
          "[SupabaseStorage] SUPABASE_SERVICE_KEY does not look like a JWT (expected 3 dot-separated segments)"
        )
      end

      url = "#{config.url}/storage/v1/object/#{bucket}/#{remote_path}"

      case File.read(local_path) do
        {:ok, content} ->
          request = Finch.build(:put, url, headers, content)

          case Finch.request(request, Vibe.Finch, receive_timeout: 120_000) do
            {:ok, %{status: status}} when status in [200, 201] ->
              public_url = get_public_url(remote_path, bucket)
              Logger.info("[SupabaseStorage] Uploaded: #{remote_path}")
              {:ok, public_url}

            {:ok, %{status: status, body: body}} ->
              Logger.error("[SupabaseStorage] Upload failed: #{status} - #{body}")
              {:error, "Upload failed: #{status} - #{truncate_body(body)}"}

            {:error, reason} ->
              Logger.error("[SupabaseStorage] Upload error: #{inspect(reason)}")
              {:error, "Upload error: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, "Could not read file: #{inspect(reason)}"}
      end
    end
  end

  defp truncate_body(body) when is_binary(body) do
    max = 600
    if byte_size(body) > max, do: binary_part(body, 0, max) <> "...", else: body
  end

  defp truncate_body(body), do: inspect(body)

  @doc """
  Check if a file exists in storage.
  """
  def exists?(remote_path) do
    config = get_config()

    unless config.url && config.service_key && config.service_key != "" do
      false
    else
      bucket = resolve_bucket(config, :music)
      url = "#{config.url}/storage/v1/object/info/#{bucket}/#{remote_path}"

      {headers, _service_key} = build_auth_headers(config)

      request = Finch.build(:get, url, headers)

      case Finch.request(request, Vibe.Finch, receive_timeout: 10_000) do
        {:ok, %{status: 200}} -> true
        _ -> false
      end
    end
  end

  @doc """
  Delete a file from storage.
  """
  def delete(remote_path) do
    config = get_config()

    unless config.url && config.service_key && config.service_key != "" do
      {:error, "Supabase not configured"}
    else
      bucket = resolve_bucket(config, :music)
      url = "#{config.url}/storage/v1/object/#{bucket}/#{remote_path}"

      {headers, _service_key} = build_auth_headers(config)

      request = Finch.build(:delete, url, headers)

      case Finch.request(request, Vibe.Finch, receive_timeout: 10_000) do
        {:ok, %{status: status}} when status in [200, 204] -> :ok
        {:ok, %{status: status, body: body}} -> {:error, "Delete failed: #{status} - #{body}"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  @doc """
  Get the public client URL for a file. When MEDIA_CDN_BASE_URL is configured,
  this points to the CDN hostname instead of the raw Supabase public object URL.
  """
  def get_public_url(remote_path) do
    config = get_config()
    bucket = resolve_bucket(config, :music)
    get_public_url(remote_path, bucket)
  end

  def get_public_url(remote_path, bucket) when is_binary(bucket) do
    config = get_config()
    raw_url = raw_public_url(remote_path, bucket, config)
    rewrite_public_url(raw_url, config)
  end

  @doc """
  Get the raw Supabase public object URL for a file.
  """
  def get_origin_public_url(remote_path) do
    config = get_config()
    bucket = resolve_bucket(config, :music)
    raw_public_url(remote_path, bucket, config)
  end

  def get_origin_public_url(remote_path, bucket) when is_binary(bucket) do
    raw_public_url(remote_path, bucket, get_config())
  end

  @doc """
  Rewrite a historical/raw Supabase public object URL to the configured CDN URL.
  If MEDIA_CDN_BASE_URL is unset or the URL cannot be recognized, the input is returned.
  """
  def rewrite_public_url(nil), do: nil

  def rewrite_public_url(url) when is_binary(url) do
    config = get_config()
    rewrite_public_url(url, config)
  end

  def rewrite_public_url(other), do: other

  defp rewrite_public_url(url, config) when is_binary(url) do
    with cdn_base when is_binary(cdn_base) <- normalize_base_url(config.media_cdn_base_url),
         {:ok, bucket, object_path, suffix} <- extract_public_object_components(url) do
      "#{cdn_base}/#{bucket}/#{object_path}#{suffix}"
    else
      _ -> url
    end
  end

  defp rewrite_public_url(other, _config), do: other

  defp get_config do
    config = Application.get_env(:vibe, :supabase, [])
    %{
      url: config[:url] || System.get_env("SUPABASE_URL"),
      key: config[:key] || System.get_env("SUPABASE_KEY"),
      service_key: config[:service_key] || System.get_env("SUPABASE_SERVICE_KEY"),
      media_cdn_base_url: config[:media_cdn_base_url] || System.get_env("MEDIA_CDN_BASE_URL"),
      bucket: config[:bucket] || System.get_env("SUPABASE_BUCKET"),
      media_bucket: config[:media_bucket] || System.get_env("SUPABASE_MEDIA_BUCKET"),
      music_bucket: config[:music_bucket] || System.get_env("SUPABASE_MUSIC_BUCKET")
    }
  end

  defp raw_public_url(remote_path, bucket, config) do
    "#{config.url}/storage/v1/object/public/#{bucket}/#{remote_path}"
  end

  defp extract_public_object_components(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: path} = uri when is_binary(path) ->
        case String.split(path, @public_object_marker, parts: 2) do
          [_prefix, suffix] ->
            parts = suffix |> String.split("/", trim: true)

            case parts do
              [bucket | rest] when rest != [] ->
                normalized_rest =
                  case rest do
                    [^bucket | tail] when tail != [] -> tail
                    _ -> rest
                  end

                object_path = Enum.join(normalized_rest, "/")
                query = if is_binary(uri.query), do: "?#{uri.query}", else: ""
                fragment = if is_binary(uri.fragment), do: "##{uri.fragment}", else: ""
                {:ok, bucket, object_path, query <> fragment}

              _ ->
                :error
            end

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp normalize_base_url(nil), do: nil

  defp normalize_base_url(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      true -> String.trim_trailing(trimmed, "/")
    end
  end

  defp get_content_type(path) do
    cond do
      String.ends_with?(path, ".m4a") -> "audio/mp4"
      String.ends_with?(path, ".mp3") -> "audio/mpeg"
      String.ends_with?(path, ".mp4") -> "video/mp4"
      String.ends_with?(path, ".webm") -> "audio/webm"
      String.ends_with?(path, ".jpg") -> "image/jpeg"
      String.ends_with?(path, ".jpeg") -> "image/jpeg"
      String.ends_with?(path, ".png") -> "image/png"
      String.ends_with?(path, ".gif") -> "image/gif"
      String.ends_with?(path, ".webp") -> "image/webp"
      String.ends_with?(path, ".heic") -> "image/heic"
      String.ends_with?(path, ".wav") -> "audio/wav"
      String.ends_with?(path, ".mov") -> "video/quicktime"
      String.ends_with?(path, ".pdf") -> "application/pdf"
      String.ends_with?(path, ".csv") -> "text/csv"
      String.ends_with?(path, ".txt") -> "text/plain"
      String.ends_with?(path, ".json") -> "application/json"
      String.ends_with?(path, ".xlsx") -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      true -> "application/octet-stream"
    end
  end
end
