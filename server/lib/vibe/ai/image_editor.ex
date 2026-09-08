defmodule Vibe.AI.ImageEditor do
  @moduledoc """
  AI image editing.
  """

  require Logger

  alias Vibe.AI.Multipart
  alias Vibe.AI.Tools.Vision
  alias Vibe.Net.SafeURL

  @openai_base "https://api.openai.com/v1"
  @openai_image_model "gpt-image-2"

  @gemini_api "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro-image-preview:generateContent"

  # Provider hard limit is 50MB per image.
  @max_image_bytes 40_000_000

  @type source :: String.t() | {:bytes, binary(), String.t()}

  @doc """
  Edits an image from a prompt.
  """
  @spec edit_image(source, String.t(), keyword()) ::
          {:ok, %{bytes: binary(), mime_type: String.t()}} | {:error, String.t()}
  def edit_image(source, prompt, opts \\ [])

  def edit_image(source, prompt, opts) when is_binary(prompt) and prompt != "" do
    case System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and key != "" ->
        with {:ok, bytes, mime} <- read_source(source) do
          edit_with_openai(key, bytes, mime, prompt, opts)
        end

      _ ->
        Logger.warning("[ImageEditor] OPENAI_API_KEY unset — falling back to Gemini (no mask support)")
        edit_with_gemini(source, prompt)
    end
  end

  def edit_image(_source, _prompt, _opts), do: {:error, "prompt cannot be empty"}


  defp edit_with_openai(api_key, bytes, mime, prompt, opts) do
    base_url = System.get_env("OPENAI_BASE_URL") || @openai_base
    model = System.get_env("OPENAI_IMAGE_MODEL") || @openai_image_model

    Logger.info(
      "[ImageEditor] openai edit model=#{model} bytes=#{byte_size(bytes)} " <>
        "mask=#{if opts[:mask], do: "yes", else: "no"} prompt=<redacted #{byte_size(prompt)} bytes>"
    )

    parts =
      [
        {"model", model},
        {"prompt", prompt},
        {"n", "1"},
        {"quality", opts[:quality] || "high"}
      ]
      |> maybe_field("size", opts[:size])
      |> maybe_file("mask", opts[:mask])
      |> Kernel.++([{"image[]", {:file, "source.#{ext_for(mime)}", mime, bytes}}])

    {content_type, body} = Multipart.encode(parts)

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", content_type}
    ]

    :post
    |> Finch.build("#{base_url}/images/edits", headers, body)
    |> Finch.request(Vibe.Finch, receive_timeout: 180_000)
    |> handle_openai_response()
  end

  defp handle_openai_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, %{"data" => [%{"b64_json" => b64} | _]}} ->
        decoded_image(b64, "image/png")

      {:ok, other} ->
        Logger.error("[ImageEditor] unexpected OpenAI shape: #{inspect(Map.keys(other))}")
        {:error, "Unexpected response from image model"}

      {:error, _} ->
        {:error, "Failed to parse image model response"}
    end
  end

  defp handle_openai_response({:ok, %{status: status, body: body}}) do
    Logger.error("[ImageEditor] OpenAI edit failed #{status}: #{truncate(body)}")
    {:error, "Image model error (#{status})"}
  end

  defp handle_openai_response({:error, reason}) do
    Logger.error("[ImageEditor] OpenAI request failed: #{inspect(reason)}")
    {:error, "Image model request failed"}
  end


  defp edit_with_gemini(source, prompt) do
    case System.get_env("GEMINI_API_KEY") do
      key when is_binary(key) and key != "" ->
        with {:ok, bytes, mime} <- read_source(source) do
          call_gemini_edit(key, Base.encode64(bytes), mime, prompt)
        end

      _ ->
        {:error, "No image model configured (set OPENAI_API_KEY)"}
    end
  end

  defp call_gemini_edit(api_key, base64_data, mime_type, prompt) do
    body =
      Jason.encode!(%{
        contents: [
          %{
            parts: [
              %{text: "Edit this image: #{prompt}. Return the edited image."},
              %{inline_data: %{mime_type: mime_type, data: base64_data}}
            ]
          }
        ],
        generationConfig: %{temperature: 0.4, maxOutputTokens: 2048}
      })

    :post
    |> Finch.build("#{@gemini_api}?key=#{api_key}", [{"content-type", "application/json"}], body)
    |> Finch.request(Vibe.Finch, receive_timeout: 60_000)
    |> case do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_gemini_image(resp_body)

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("[ImageEditor] Gemini error #{status}: #{truncate(resp_body)}")
        {:error, "Image model error (#{status})"}

      {:error, reason} ->
        Logger.error("[ImageEditor] Gemini request failed: #{inspect(reason)}")
        {:error, "Image model request failed"}
    end
  end

  defp parse_gemini_image(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"candidates" => [%{"content" => %{"parts" => parts}} | _]}} ->
        parts
        |> Enum.find(&(Map.has_key?(&1, "inline_data") or Map.has_key?(&1, "inlineData")))
        |> case do
          nil ->
            text = Enum.map_join(parts, "", &(&1["text"] || ""))
            {:error, "No image generated. Model said: #{String.slice(text, 0, 120)}"}

          part ->
            data = part["inline_data"] || part["inlineData"]
            decoded_image(data["data"], data["mime_type"] || data["mimeType"])
        end

      _ ->
        {:error, "Failed to parse Gemini response"}
    end
  end


  defp read_source({:bytes, bytes, mime}) when is_binary(bytes) do
    if byte_size(bytes) > @max_image_bytes do
      {:error, "Image too large (max #{div(@max_image_bytes, 1_000_000)}MB)"}
    else
      {:ok, bytes, mime || "image/png"}
    end
  end

  defp read_source("data:" <> _ = data_url), do: decode_data_url(data_url)

  defp read_source("http" <> _ = url) do
    with {:ok, _uri} <- SafeURL.validate(url),
         {:ok, data_url} <- Vision.fetch_and_encode(url) do
      decode_data_url(data_url)
    end
  end

  defp read_source(_), do: {:error, "Invalid image source"}

  defp decode_data_url(data_url) do
    with [header, data] <- String.split(data_url, ";base64,", parts: 2),
         {:ok, bytes} <- Base.decode64(data, ignore: :whitespace) do
      read_source({:bytes, bytes, String.replace(header, "data:", "")})
    else
      _ -> {:error, "Invalid data URL"}
    end
  end


  defp decoded_image(base64_data, mime_type) when is_binary(base64_data) do
    case Base.decode64(base64_data, ignore: :whitespace) do
      {:ok, binary} -> {:ok, %{bytes: binary, mime_type: mime_type || "image/png"}}
      :error -> {:error, "Failed to decode generated image"}
    end
  end

  defp decoded_image(_, _), do: {:error, "Image model returned no data"}


  defp maybe_field(parts, _key, nil), do: parts
  defp maybe_field(parts, _key, ""), do: parts
  defp maybe_field(parts, key, value), do: parts ++ [{key, to_string(value)}]

  defp maybe_file(parts, _key, nil), do: parts

  defp maybe_file(parts, key, {:bytes, bytes, mime}) do
    parts ++ [{key, {:file, "#{key}.#{ext_for(mime)}", mime || "image/png", bytes}}]
  end

  defp ext_for("image/jpeg"), do: "jpg"
  defp ext_for("image/jpg"), do: "jpg"
  defp ext_for("image/webp"), do: "webp"
  defp ext_for(_), do: "png"

  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 400)
  defp truncate(body), do: body |> inspect() |> String.slice(0, 400)
end
