defmodule Vibe.AI.Tools.Vision do
  @moduledoc """
  Image analysis tool using Claude's vision capabilities.
  """

  require Logger
  alias Vibe.Net.SafeURL

  @claude_api "https://api.anthropic.com/v1/messages"
  @claude_model "claude-sonnet-4-20250514"

  @doc """
  Analyze an image and return structured information.
  """
  def analyze(%{"image_url" => image_url} = params) do
    task = params["task"] || "describe"

    prompt = case task do
      "describe" ->
        "Describe this image in detail. Include notable objects, people, text, colors, and mood."

      "ocr" ->
        "Extract ALL text visible in this image. Format it clearly, preserving any structure like lists or tables."

      "identify" ->
        "Identify what's in this image: objects, brands, landmarks, or notable elements. Be specific."

      custom when is_binary(custom) ->
        custom

      _ ->
        "Analyze this image and describe what you see."
    end

    call_claude_vision(image_url, prompt)
  end

  defp call_claude_vision(image_url, prompt) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_API_KEY")

    unless api_key do
      %{error: "ANTHROPIC_API_KEY not configured"}
    else
      case prepare_image(image_url) do
        {:ok, image_content} ->
          body = Jason.encode!(%{
            model: @claude_model,
            max_tokens: 1024,
            messages: [
              %{
                role: "user",
                content: [
                  image_content,
                  %{type: "text", text: prompt}
                ]
              }
            ]
          })

          headers = [
            {"Content-Type", "application/json"},
            {"x-api-key", api_key},
            {"anthropic-version", "2023-06-01"}
          ]

          case Finch.build(:post, @claude_api, headers, body) |> Finch.request(Vibe.Finch) do
            {:ok, %{status: 200, body: resp_body}} ->
              case Jason.decode(resp_body) do
                {:ok, %{"content" => [%{"text" => text} | _]}} ->
                  %{
                    success: true,
                    analysis: text,
                    image_url: image_url
                  }
                _ ->
                  %{error: "Failed to parse response"}
              end

            {:ok, %{status: status, body: resp_body}} ->
              Logger.error("Claude Vision error: #{status} - #{resp_body}")
              %{error: "API error: #{status}"}

            {:error, reason} ->
              Logger.error("Claude Vision request failed: #{inspect(reason)}")
              %{error: "Request failed"}
          end

        {:error, reason} ->
          %{error: "Failed to process image: #{reason}"}
      end
    end
  end

  defp prepare_image(url) when is_binary(url) do
    cond do
      String.starts_with?(url, "http") ->
        {:ok, %{
          type: "image",
          source: %{
            type: "url",
            url: url
          }
        }}

      String.starts_with?(url, "data:image/") ->
        [header, data] = String.split(url, ",", parts: 2)
        media_type = header
          |> String.replace("data:", "")
          |> String.replace(";base64", "")

        {:ok, %{
          type: "image",
          source: %{
            type: "base64",
            media_type: media_type,
            data: data
          }
        }}

      true ->
        {:error, "Invalid image URL format"}
    end
  end

  @doc """
  Download an image and convert to base64.
  Useful for images that Claude can't access directly.
  """
  def fetch_and_encode(url) do
    with {:ok, _uri} <- SafeURL.validate(url),
         {:ok, %{status: 200, body: body, headers: headers}} <-
           Finch.build(:get, url) |> Finch.request(Vibe.Finch) do
        content_type = Enum.find_value(headers, "image/jpeg", fn
          {"content-type", ct} -> ct
          _ -> nil
        end)

        base64 = Base.encode64(body)
        {:ok, "data:#{content_type};base64,#{base64}"}
    else
      _ -> {:error, "Failed to download image"}
    end
  end
end
