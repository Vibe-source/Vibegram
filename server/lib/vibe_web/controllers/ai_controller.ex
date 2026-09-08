defmodule VibeWeb.AIController do
  @moduledoc """
  AI media editing endpoints.
  """
  use VibeWeb, :controller

  alias Vibe.AI.ImageEditor
  alias Vibe.AI.VideoEditor

  require Logger

  @max_image_bytes 40_000_000
  # Must stay under the endpoint's Plug.Parsers `length` (MAX_REQUEST_BYTES.
  @max_video_bytes 100_000_000

  @doc """
  Edit an image using AI.
  """
  def edit_image(conn, %{"image" => %Plug.Upload{} = upload, "prompt" => prompt} = params)
      when is_binary(prompt) and byte_size(prompt) > 0 do
    with {:ok, bytes} <- read_upload(upload, @max_image_bytes),
         {:ok, mask} <- read_optional_mask(params) do
      opts =
        [mask: mask]
        |> put_opt(:size, params["size"])
        |> put_opt(:quality, params["quality"])

      Logger.info(
        "[AIController] edit_image multipart bytes=#{byte_size(bytes)} " <>
          "mask=#{if mask, do: "yes", else: "no"} prompt=<redacted #{byte_size(prompt)} bytes>"
      )

      {:bytes, bytes, upload.content_type || "image/png"}
      |> ImageEditor.edit_image(prompt, opts)
      |> respond_image(conn)
    else
      {:error, reason} -> bad_request(conn, "Failed to edit image", reason)
    end
  end

  def edit_image(conn, %{"image_url" => image_url, "prompt" => prompt})
      when is_binary(image_url) and is_binary(prompt) and byte_size(prompt) > 0 do
    Logger.info("[AIController] edit_image url prompt=<redacted #{byte_size(prompt)} bytes>")

    image_url
    |> ImageEditor.edit_image(prompt, [])
    |> respond_image(conn)
  end

  def edit_image(conn, params) do
    Logger.warning("[AIController] edit_image called with invalid params keys=#{inspect(Map.keys(params))}")

    bad_request(
      conn,
      "Missing or invalid parameters",
      "Provide multipart `image` (plus optional `mask`) or `image_url`, and a non-empty `prompt`"
    )
  end

  @doc """
  Edit a short video clip using AI (Gemini Omni Flash).
  """
  def edit_video(conn, %{"video" => %Plug.Upload{} = upload, "prompt" => prompt} = params)
      when is_binary(prompt) and byte_size(prompt) > 0 do
    case read_upload(upload, @max_video_bytes) do
      {:ok, bytes} ->
        opts =
          []
          |> put_opt(:previous_interaction_id, params["previous_interaction_id"])
          |> put_opt(:aspect_ratio, params["aspect_ratio"])

        Logger.info(
          "[AIController] edit_video bytes=#{byte_size(bytes)} " <>
            "continue=#{if opts[:previous_interaction_id], do: "yes", else: "no"} " <>
            "prompt=<redacted #{byte_size(prompt)} bytes>"
        )

        case VideoEditor.edit_video(bytes, upload.content_type || "video/mp4", prompt, opts) do
          {:ok, %{bytes: out, mime_type: mime, interaction_id: id}} ->
            json(conn, %{
              success: true,
              mime_type: mime,
              video_b64: Base.encode64(out),
              interaction_id: id
            })

          {:error, reason} ->
            Logger.error("[AIController] edit_video failed: #{inspect(reason)}")
            bad_request(conn, "Failed to edit video", reason)
        end

      {:error, reason} ->
        bad_request(conn, "Failed to edit video", reason)
    end
  end

  def edit_video(conn, params) do
    Logger.warning("[AIController] edit_video called with invalid params keys=#{inspect(Map.keys(params))}")

    bad_request(
      conn,
      "Missing or invalid parameters",
      "Provide multipart `video` (10s or less) and a non-empty `prompt`"
    )
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp respond_image({:ok, %{bytes: bytes, mime_type: mime}}, conn) do
    json(conn, %{success: true, mime_type: mime, image_b64: Base.encode64(bytes)})
  end

  defp respond_image({:error, reason}, conn) do
    Logger.error("[AIController] edit_image failed: #{inspect(reason)}")
    bad_request(conn, "Failed to edit image", reason)
  end

  defp read_optional_mask(%{"mask" => %Plug.Upload{} = mask}) do
    case read_upload(mask, @max_image_bytes) do
      {:ok, bytes} -> {:ok, {:bytes, bytes, mask.content_type || "image/png"}}
      error -> error
    end
  end

  defp read_optional_mask(_params), do: {:ok, nil}

  defp read_upload(%Plug.Upload{path: path}, max_bytes) do
    with {:ok, %{size: size}} <- File.stat(path),
         true <- size <= max_bytes,
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      false -> {:error, "File too large (max #{div(max_bytes, 1_000_000)}MB)"}
      {:error, reason} -> {:error, "Could not read upload: #{inspect(reason)}"}
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, ""), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp bad_request(conn, error, details) do
    conn
    |> put_status(:bad_request)
    |> json(%{success: false, error: error, details: stringify(details)})
  end

  defp stringify(details) when is_binary(details), do: details
  defp stringify(details) when is_atom(details) or is_number(details), do: to_string(details)
  defp stringify(details), do: inspect(details)
end
