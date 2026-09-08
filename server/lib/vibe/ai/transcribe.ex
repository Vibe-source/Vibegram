defmodule Vibe.AI.Transcribe do
  @moduledoc """
  Speech → text for voice notes sent to an agent. Without this a voice-only message reaches
  the agent as an empty prompt, so nothing is dispatched at all.
  """

  require Logger

  @api "https://api.openai.com/v1/audio/transcriptions"
  @model "gpt-4o-transcribe"
  @max_bytes 25 * 1024 * 1024
  @download_timeout 30_000
  @transcribe_timeout 120_000

  @doc "First audio url that transcribes to something, or nil. Never raises."
  def voice_text(urls) when is_list(urls) do
    Enum.find_value(urls, fn url ->
      case transcribe_url(url) do
        {:ok, text} -> text
        {:error, _reason} -> nil
      end
    end)
  end

  def voice_text(_urls), do: nil

  def transcribe_url(url) when is_binary(url) do
    with {:ok, _uri} <- Vibe.Net.SafeURL.validate(url),
         {:ok, key} <- api_key(),
         {:ok, audio} <- download(url) do
      transcribe(audio, filename(url), key)
    end
  end

  def transcribe_url(_url), do: {:error, :invalid_url}

  defp api_key do
    case System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end

  defp download(url) do
    case Finch.request(Finch.build(:get, url), Vibe.Finch, receive_timeout: @download_timeout) do
      {:ok, %{status: 200, body: body}} when byte_size(body) <= @max_bytes ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        Logger.warning("[Transcribe] audio too large: #{byte_size(body)} bytes")
        {:error, :too_large}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transcribe(audio, name, key) do
    boundary = "vibe-#{Ecto.UUID.generate()}"
    body = multipart(boundary, name, audio)

    headers = [
      {"authorization", "Bearer #{key}"},
      {"content-type", "multipart/form-data; boundary=#{boundary}"}
    ]

    case Finch.request(Finch.build(:post, @api, headers, body), Vibe.Finch,
           receive_timeout: @transcribe_timeout
         ) do
      {:ok, %{status: 200, body: json}} ->
        case Jason.decode(json) do
          {:ok, %{"text" => text}} when is_binary(text) ->
            trimmed = String.trim(text)
            if trimmed == "", do: {:error, :empty}, else: {:ok, trimmed}

          _ ->
            {:error, :unparseable}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("[Transcribe] OpenAI returned #{status}: #{inspect(body)}")
        {:error, :transcribe_failed}

      {:error, reason} ->
        Logger.error("[Transcribe] request failed: #{inspect(reason)}")
        {:error, :transcribe_failed}
    end
  end

  defp multipart(boundary, name, audio) do
    part = fn field, value ->
      "--#{boundary}\r\ncontent-disposition: form-data; name=\"#{field}\"\r\n\r\n#{value}\r\n"
    end

    part.("model", @model) <>
      part.("response_format", "json") <>
      "--#{boundary}\r\n" <>
      "content-disposition: form-data; name=\"file\"; filename=\"#{name}\"\r\n" <>
      "content-type: application/octet-stream\r\n\r\n" <>
      audio <> "\r\n--#{boundary}--\r\n"
  end

  defp filename(url) do
    ext = url |> URI.parse() |> Map.get(:path, "") |> to_string() |> Path.extname() |> String.downcase()
    if ext in [".mp3", ".m4a", ".wav", ".webm", ".ogg", ".oga", ".mp4", ".mpga", ".flac"],
      do: "voice#{ext}",
      else: "voice.m4a"
  end
end
