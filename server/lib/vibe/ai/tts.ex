defmodule Vibe.AI.TTS do
  @moduledoc false

  require Logger

  alias Vibe.Storage

  @openai_tts_api "https://api.openai.com/v1/audio/speech"

  def synthesize(text, opts \\ [])

  def synthesize(text, opts) when is_binary(text) do
    api_key = System.get_env("OPENAI_API_KEY")
    voice = Keyword.get(opts, :voice, "alloy")

    cond do
      String.trim(text) == "" ->
        {:error, :empty_text}

      is_nil(api_key) or String.trim(api_key) == "" ->
        {:error, :missing_api_key}

      true ->
        body =
          Jason.encode!(%{
            model: "gpt-4o-mini-tts",
            voice: voice,
            input: text,
            format: "mp3"
          })

        headers = [
          {"content-type", "application/json"},
          {"authorization", "Bearer #{api_key}"}
        ]

        request = Finch.build(:post, @openai_tts_api, headers, body)

        case Finch.request(request, Vibe.Finch, receive_timeout: 60_000) do
          {:ok, %{status: 200, body: audio_bin}} ->
            persist_audio(audio_bin)

          {:ok, %{status: status, body: body}} ->
            Logger.error("[TTS] OpenAI returned #{status}: #{inspect(body)}")
            {:error, :tts_failed}

          {:error, reason} ->
            Logger.error("[TTS] request failed: #{inspect(reason)}")
            {:error, :tts_failed}
        end
    end
  end

  def synthesize(_text, _opts), do: {:error, :invalid_text}

  defp persist_audio(audio_bin) do
    temp_path = Path.join(System.tmp_dir!(), "vibe-agent-voice-#{Ecto.UUID.generate()}.mp3")
    remote_path = "agents/voice/#{Ecto.UUID.generate()}.mp3"

    with :ok <- File.write(temp_path, audio_bin),
         {:ok, public_url} <- Storage.upload(temp_path, remote_path, bucket: :media) do
      duration = estimated_duration_seconds(audio_bin)
      File.rm(temp_path)
      {:ok, %{media_url: public_url, duration: duration}}
    else
      error ->
        File.rm(temp_path)
        error
    end
  end

  defp estimated_duration_seconds(audio_bin) when is_binary(audio_bin) do
    max(Float.round(byte_size(audio_bin) / 3_000, 1), 1.0)
  end
end
