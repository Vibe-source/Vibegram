defmodule Vibe.R2Storage do
  @moduledoc """
  Cloudflare R2 storage client — a private-bucket counterpart to `Vibe.SupabaseStorage`.
  """

  require Logger

  # Default read TTL:
  @default_ttl_seconds 15 * 60
  # ExAws.S3.presigned_url/5 itself refuses expires_in beyond one week.
  @max_ttl_seconds 7 * 24 * 60 * 60

  # 24 random bytes = 192 bits of entropy.
  @key_random_bytes 24

  # Extensions we know Vibe media can be.
  @allowed_extensions ~w(.m4a .mp3 .mp4 .webm .jpg .jpeg .png .gif .webp .heic .wav .mov .pdf .csv .txt .json .xlsx)

  # --- config --------------------------------------------------------------

  defp get_config do
    config = Application.get_env(:vibe, :r2, [])

    %{
      account_id: config[:account_id] || System.get_env("R2_ACCOUNT_ID"),
      access_key_id: config[:access_key_id] || System.get_env("R2_ACCESS_KEY_ID"),
      secret_access_key: config[:secret_access_key] || System.get_env("R2_SECRET_ACCESS_KEY"),
      bucket: config[:bucket] || System.get_env("R2_BUCKET"),
      public_base_url: config[:public_base_url] || System.get_env("R2_PUBLIC_BASE_URL")
    }
  end

  @doc """
  Whether R2 has everything it needs to serve a request.
  """
  def configured?, do: configured?(get_config())

  @doc """
  Rewrite an R2 object URL onto the configured public base.
  """
  def rewrite_public_url(url) when is_binary(url) do
    config = get_config()

    with %URI{host: host, path: path} when is_binary(host) and is_binary(path) <- URI.parse(url),
         true <- storage_host?(host, config),
         key when is_binary(key) and key != "" <- object_key_from_path(path, config.bucket) do
      durable_object_url(key)
    else
      _ -> url
    end
  end

  def rewrite_public_url(url), do: url

  defp object_key_from_path(path, bucket) do
    path
    |> String.trim_leading("/")
    |> String.replace_prefix("#{bucket}/", "")
    |> case do
      "" -> nil
      key -> key
    end
  end

  defp durable_object_url(key) do
    base =
      System.get_env("PUBLIC_BASE_URL") ||
        System.get_env("API_BASE_URL") ||
        VibeWeb.Endpoint.url()

    String.trim_trailing(base, "/") <> "/api/media/o/" <> URI.encode(key)
  end

  defp storage_host?(host, config) do
    normalized_host = String.downcase(host)

    normalized_host == "#{config.account_id}.r2.cloudflarestorage.com" or
      String.ends_with?(normalized_host, ".r2.cloudflarestorage.com") or
      normalized_host == public_base_host(config.public_base_url)
  end

  defp public_base_host(value) when is_binary(value) do
    case URI.parse(value).host do
      host when is_binary(host) -> String.downcase(host)
      _ -> nil
    end
  end

  defp public_base_host(_), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp configured?(config) do
    present?(config.account_id) and
      present?(config.access_key_id) and
      present?(config.secret_access_key) and
      present?(config.bucket)
  end

  defp missing_config_error do
    Logger.error(
      "[R2Storage] Missing config, refusing (need R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET)"
    )

    {:error, "R2 not configured"}
  end

  defp ex_aws_config(config) do
    ExAws.Config.new(:s3,
      access_key_id: config.access_key_id,
      secret_access_key: config.secret_access_key,
      region: "auto",
      host: "#{config.account_id}.r2.cloudflarestorage.com",
      scheme: "https://",
      port: 443
    )
  end


  @doc """
  Generates an unguessable object key: `:crypto.strong_rand_bytes/1` output only.
  """
  def generate_object_key(source_path \\ nil) do
    random =
      @key_random_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    case safe_extension(source_path) do
      nil -> random
      ext -> random <> ext
    end
  end

  defp safe_extension(path) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()
    if ext in @allowed_extensions, do: ext, else: nil
  end

  defp safe_extension(_), do: nil


  @doc """
  Upload a file to R2 under a freshly generated.
  """
  def upload(local_path, remote_path), do: upload(local_path, remote_path, [])

  def upload(local_path, remote_path, opts) when is_list(opts) do
    config = get_config()

    if configured?(config) do
      key = generate_object_key(remote_path)

      case File.read(local_path) do
        {:ok, content} -> do_put(config, key, content, remote_path, opts)
        {:error, reason} -> {:error, "Could not read file: #{inspect(reason)}"}
      end
    else
      missing_config_error()
    end
  end

  defp do_put(config, key, content, remote_path, opts) do
    aws_config = ex_aws_config(config)
    bucket = resolve_bucket(config, opts)

    case ExAws.S3.presigned_url(aws_config, :put, bucket, key, expires_in: 300) do
      {:ok, put_url} ->
        headers = [{"Content-Type", get_content_type(remote_path)}]
        request = Finch.build(:put, put_url, headers, content)

        case Finch.request(request, Vibe.Finch, receive_timeout: 120_000) do
          {:ok, %{status: status}} when status in [200, 201] ->
            Logger.info("[R2Storage] Uploaded: #{key}")
            get_presigned_url(key, opts)

          {:ok, %{status: status, body: body}} ->
            Logger.error("[R2Storage] Upload failed: #{status} - #{body}")
            {:error, "Upload failed: #{status} - #{truncate_body(body)}"}

          {:error, reason} ->
            Logger.error("[R2Storage] Upload error: #{inspect(reason)}")
            {:error, "Upload error: #{inspect(reason)}"}
        end

      {:error, reason} ->
        Logger.error("[R2Storage] Failed to presign upload: #{inspect(reason)}")
        {:error, "Failed to presign upload: #{inspect(reason)}"}
    end
  end

  @doc """
  Check whether an object exists.
  """
  def exists?(remote_path) do
    config = get_config()

    if configured?(config) do
      aws_config = ex_aws_config(config)
      bucket = resolve_bucket(config, [])

      case ExAws.S3.presigned_url(aws_config, :head, bucket, remote_path, expires_in: 60) do
        {:ok, head_url} ->
          request = Finch.build(:head, head_url)

          case Finch.request(request, Vibe.Finch, receive_timeout: 10_000) do
            {:ok, %{status: 200}} -> true
            _ -> false
          end

        {:error, _reason} ->
          false
      end
    else
      false
    end
  end

  @doc """
  Delete an object from storage.
  """
  def delete(remote_path) do
    config = get_config()

    if configured?(config) do
      aws_config = ex_aws_config(config)
      bucket = resolve_bucket(config, [])

      case ExAws.S3.presigned_url(aws_config, :delete, bucket, remote_path, expires_in: 60) do
        {:ok, delete_url} ->
          request = Finch.build(:delete, delete_url)

          case Finch.request(request, Vibe.Finch, receive_timeout: 10_000) do
            {:ok, %{status: status}} when status in [200, 204] -> :ok
            {:ok, %{status: status, body: body}} -> {:error, "Delete failed: #{status} - #{body}"}
            {:error, reason} -> {:error, inspect(reason)}
          end

        {:error, reason} ->
          {:error, "Failed to presign delete: #{inspect(reason)}"}
      end
    else
      {:error, "R2 not configured"}
    end
  end

  @doc """
  The URL accessor for this backend — deliberately not called `get_public_url`.
  """
  def get_presigned_url(remote_path), do: get_presigned_url(remote_path, [])

  def get_presigned_url(remote_path, opts) when is_list(opts) do
    config = get_config()

    if configured?(config) do
      aws_config = ex_aws_config(config)
      bucket = resolve_bucket(config, opts)
      ttl = resolve_ttl(opts)

      case ExAws.S3.presigned_url(aws_config, :get, bucket, remote_path, expires_in: ttl) do
        {:ok, url} -> {:ok, url}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      missing_config_error()
    end
  end

  defp resolve_bucket(config, opts) do
    case Keyword.get(opts, :bucket) do
      bucket when is_binary(bucket) and bucket != "" -> bucket
      _ -> config.bucket
    end
  end

  defp resolve_ttl(opts) do
    opts
    |> Keyword.get(:ttl, @default_ttl_seconds)
    |> clamp_ttl()
  end

  defp clamp_ttl(ttl) when is_integer(ttl) and ttl > 0, do: min(ttl, @max_ttl_seconds)
  defp clamp_ttl(_), do: @default_ttl_seconds

  defp truncate_body(body) when is_binary(body) do
    max = 600
    if byte_size(body) > max, do: binary_part(body, 0, max) <> "...", else: body
  end

  defp truncate_body(body), do: inspect(body)

  defp get_content_type(path) when is_binary(path) do
    cond do
      String.ends_with?(path, ".m4a") ->
        "audio/mp4"

      String.ends_with?(path, ".mp3") ->
        "audio/mpeg"

      String.ends_with?(path, ".mp4") ->
        "video/mp4"

      String.ends_with?(path, ".webm") ->
        "audio/webm"

      String.ends_with?(path, ".jpg") ->
        "image/jpeg"

      String.ends_with?(path, ".jpeg") ->
        "image/jpeg"

      String.ends_with?(path, ".png") ->
        "image/png"

      String.ends_with?(path, ".gif") ->
        "image/gif"

      String.ends_with?(path, ".webp") ->
        "image/webp"

      String.ends_with?(path, ".heic") ->
        "image/heic"

      String.ends_with?(path, ".wav") ->
        "audio/wav"

      String.ends_with?(path, ".mov") ->
        "video/quicktime"

      String.ends_with?(path, ".pdf") ->
        "application/pdf"

      String.ends_with?(path, ".csv") ->
        "text/csv"

      String.ends_with?(path, ".txt") ->
        "text/plain"

      String.ends_with?(path, ".json") ->
        "application/json"

      String.ends_with?(path, ".xlsx") ->
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

      true ->
        "application/octet-stream"
    end
  end

  defp get_content_type(_), do: "application/octet-stream"
end
