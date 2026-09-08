defmodule Vibe.AI.VideoEditor do
  @moduledoc """
  AI video editing via Google's **Gemini Omni Flash** (`gemini-omni-flash-preview`).
  """

  require Logger

  @base "https://generativelanguage.googleapis.com"
  @model "gemini-omni-flash-preview"

  @max_duration_seconds 10
  # Files API allows 2GB, but a ≤10s clip that large means something is wrong.
  @max_input_bytes 200_000_000

  @doc """
  Edits a ≤10s video clip from a prompt.
  """
  @spec edit_video(binary(), String.t(), String.t(), keyword()) ::
          {:ok, %{bytes: binary(), mime_type: String.t(), interaction_id: String.t() | nil}}
          | {:error, String.t()}
  def edit_video(bytes, mime_type, prompt, opts \\ [])

  def edit_video(bytes, mime_type, prompt, opts)
      when is_binary(bytes) and is_binary(prompt) and prompt != "" do
    with {:ok, key} <- api_key(),
         :ok <- check_size(bytes),
         :ok <- check_duration(bytes, mime_type),
         {:ok, file_uri} <- upload_file(key, bytes, mime_type),
         {:ok, interaction} <- create_interaction(key, file_uri, prompt, opts),
         {:ok, video_bytes} <- extract_video(key, interaction) do
      {:ok, %{bytes: video_bytes, mime_type: "video/mp4", interaction_id: interaction["id"]}}
    end
  end

  def edit_video(_bytes, _mime, _prompt, _opts), do: {:error, "prompt cannot be empty"}


  defp api_key do
    case System.get_env("GEMINI_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, "No video model configured (set GEMINI_API_KEY)"}
    end
  end

  defp check_size(bytes) when byte_size(bytes) > @max_input_bytes,
    do: {:error, "Video too large"}

  defp check_size(_bytes), do: :ok

  defp check_duration(bytes, mime_type) do
    with path when is_binary(path) <- System.find_executable("ffprobe"),
         {:ok, tmp} <- write_temp(bytes, mime_type) do
      result =
        case System.cmd(
               path,
               ["-v", "error", "-show_entries", "format=duration", "-of",
                "default=noprint_wrappers=1:nokey=1", tmp],
               stderr_to_stdout: true
             ) do
          {out, 0} ->
            case Float.parse(String.trim(out)) do
              {seconds, _} when seconds > @max_duration_seconds ->
                {:error,
                 "Clip is #{Float.round(seconds, 1)}s — the video model accepts at most #{@max_duration_seconds}s. Trim the selection."}

              _ ->
                :ok
            end

          _ ->
            :ok
        end

      _ = File.rm(tmp)
      result
    else
      _ -> :ok
    end
  end

  defp write_temp(bytes, mime_type) do
    path =
      Path.join(
        System.tmp_dir!(),
        "vibe-vedit-#{System.unique_integer([:positive])}.#{ext_for(mime_type)}"
      )

    case File.write(path, bytes) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "temp write failed: #{inspect(reason)}"}
    end
  end


  defp upload_file(key, bytes, mime_type) do
    size = byte_size(bytes)

    start_headers = [
      {"x-goog-api-key", key},
      {"X-Goog-Upload-Protocol", "resumable"},
      {"X-Goog-Upload-Command", "start"},
      {"X-Goog-Upload-Header-Content-Length", Integer.to_string(size)},
      {"X-Goog-Upload-Header-Content-Type", mime_type},
      {"content-type", "application/json"}
    ]

    body = Jason.encode!(%{file: %{display_name: "vibe-edit-source"}})

    with {:ok, upload_url} <- start_upload(start_headers, body),
         {:ok, file} <- finalize_upload(upload_url, bytes, size),
         {:ok, active} <- await_active(key, file) do
      {:ok, active["uri"]}
    end
  end

  defp start_upload(headers, body) do
    :post
    |> Finch.build("#{@base}/upload/v1beta/files", headers, body)
    |> Finch.request(Vibe.Finch, receive_timeout: 60_000)
    |> case do
      {:ok, %{status: status, headers: resp_headers}} when status in 200..299 ->
        case header(resp_headers, "x-goog-upload-url") do
          nil -> {:error, "Files API did not return an upload URL"}
          url -> {:ok, url}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("[VideoEditor] files start failed #{status}: #{truncate(body)}")
        {:error, "Video upload failed (#{status})"}

      {:error, reason} ->
        Logger.error("[VideoEditor] files start error: #{inspect(reason)}")
        {:error, "Video upload failed"}
    end
  end

  defp finalize_upload(upload_url, bytes, size) do
    headers = [
      {"content-length", Integer.to_string(size)},
      {"X-Goog-Upload-Offset", "0"},
      {"X-Goog-Upload-Command", "upload, finalize"}
    ]

    :post
    |> Finch.build(upload_url, headers, bytes)
    |> Finch.request(Vibe.Finch, receive_timeout: 300_000)
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, %{"file" => file}} -> {:ok, file}
          _ -> {:error, "Could not read uploaded file handle"}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("[VideoEditor] files finalize failed #{status}: #{truncate(body)}")
        {:error, "Video upload failed (#{status})"}

      {:error, reason} ->
        Logger.error("[VideoEditor] files finalize error: #{inspect(reason)}")
        {:error, "Video upload failed"}
    end
  end

  defp await_active(key, file, attempts \\ 30)

  defp await_active(_key, _file, 0), do: {:error, "Video processing timed out"}

  defp await_active(_key, %{"state" => "ACTIVE"} = file, _attempts), do: {:ok, file}

  defp await_active(key, %{"name" => name} = _file, attempts) do
    Process.sleep(1_000)

    :get
    |> Finch.build("#{@base}/v1beta/#{name}", [{"x-goog-api-key", key}])
    |> Finch.request(Vibe.Finch, receive_timeout: 30_000)
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, %{"state" => "FAILED"}} -> {:error, "Video could not be processed"}
          {:ok, %{"state" => "ACTIVE"} = f} -> {:ok, f}
          {:ok, f} -> await_active(key, Map.put(f, "name", name), attempts - 1)
          _ -> {:error, "Could not read file state"}
        end

      _ ->
        {:error, "Could not read file state"}
    end
  end

  defp await_active(_key, _file, _attempts), do: {:error, "Uploaded file had no name"}


  defp create_interaction(key, file_uri, prompt, opts) do
    body =
      %{
        model: @model,
        input: [
          %{type: "text", text: prompt},
          %{type: "document", uri: file_uri}
        ],
        background: false,
        store: false,
        stream: false,
        generation_config: %{aspect_ratio: opts[:aspect_ratio] || "9:16"},
        response_format: %{delivery: "uri"}
      }
      |> maybe_put(:previous_interaction_id, opts[:previous_interaction_id])
      |> Jason.encode!()

    headers = [{"x-goog-api-key", key}, {"content-type", "application/json"}]

    :post
    |> Finch.build("#{@base}/v1beta/interactions", headers, body)
    |> Finch.request(Vibe.Finch, receive_timeout: 600_000)
    |> case do
      {:ok, %{status: status, body: resp}} when status in 200..299 ->
        Jason.decode(resp) |> normalize_decode()

      {:ok, %{status: status, body: resp}} ->
        Logger.error("[VideoEditor] interaction failed #{status}: #{truncate(resp)}")
        {:error, interaction_error_message(status, resp)}

      {:error, reason} ->
        Logger.error("[VideoEditor] interaction error: #{inspect(reason)}")
        {:error, "Video model request failed"}
    end
  end

  defp normalize_decode({:ok, decoded}), do: {:ok, decoded}
  defp normalize_decode(_), do: {:error, "Failed to parse video model response"}

  defp interaction_error_message(status, body) when status in [400, 403] do
    text = if is_binary(body), do: body, else: inspect(body)

    if String.contains?(text, "region") or String.contains?(text, "location") or
         String.contains?(text, "not available") do
      "Video editing is not available in this region"
    else
      "Video model error (#{status})"
    end
  end

  defp interaction_error_message(status, _body), do: "Video model error (#{status})"


  defp extract_video(key, %{"steps" => steps}) when is_list(steps) do
    steps
    |> Enum.filter(&(&1["type"] == "model_output"))
    |> Enum.flat_map(&List.wrap(&1["content"]))
    |> Enum.find(&(is_map(&1) and &1["type"] == "video"))
    |> case do
      %{"data" => data} when is_binary(data) ->
        case Base.decode64(data, ignore: :whitespace) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, "Could not decode returned video"}
        end

      %{"uri" => uri} when is_binary(uri) ->
        download(key, uri)

      _ ->
        {:error, "Video model returned no video"}
    end
  end

  defp extract_video(_key, _interaction), do: {:error, "Video model returned no video"}

  defp download(key, uri) do
    url = if String.contains?(uri, "alt=media"), do: uri, else: uri <> "?alt=media"

    :get
    |> Finch.build(url, [{"x-goog-api-key", key}])
    |> Finch.request(Vibe.Finch, receive_timeout: 300_000)
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "Could not download edited video (#{status})"}
      {:error, _} -> {:error, "Could not download edited video"}
    end
  end


  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == name, do: v
    end)
  end

  defp ext_for("video/quicktime"), do: "mov"
  defp ext_for("video/webm"), do: "webm"
  defp ext_for(_), do: "mp4"

  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 400)
  defp truncate(body), do: body |> inspect() |> String.slice(0, 400)
end
