defmodule Vibe.AI.MCP.Content do
  @moduledoc """
  Turns MCP result content blocks into what the agent loop already understands: a short text
  summary for the model, plus zero or more delivered outputs.
  """

  require Logger

  alias Vibe.Storage

  # Anything larger is refused rather than streamed through the BEAM heap and.
  @max_blob_bytes 25 * 1024 * 1024

  # One call answers with a handful of documents at most.
  @max_files_per_call 8

  @doc """
  Normalizes one `tools/call` result.
  """
  def normalize(%{content: content} = result, opts \\ []) do
    owner_id = Keyword.get(opts, :owner_id) || "agent"
    server_name = Keyword.get(opts, :server_name) || "mcp"

    {texts, outputs} =
      content
      |> Enum.reduce({[], []}, fn block, {texts, outputs} ->
        cond do
          length(outputs) >= @max_files_per_call and file_block?(block) ->
            {["(فایل‌های بیشتر نادیده گرفته شد)" | texts], outputs}

          true ->
            case block(block, owner_id, server_name) do
              {:text, value} -> {[value | texts], outputs}
              {:output, output} -> {texts, [output | outputs]}
              :skip -> {texts, outputs}
            end
        end
      end)

    outputs = Enum.reverse(outputs)

    text =
      texts
      |> Enum.reverse()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")
      |> fallback_text(outputs, result)

    %{
      text: text,
      outputs: outputs,
      files: Enum.map(outputs, &Map.get(&1, :metadata, %{})),
      structured: Map.get(result, :structured),
      is_error: Map.get(result, :is_error, false)
    }
  end

  defp file_block?(%{"type" => type}), do: type in ["image", "audio", "resource", "resource_link"]
  defp file_block?(_block), do: false

  defp block(%{"type" => "text", "text" => text}, _owner, _server) when is_binary(text) do
    {:text, text}
  end

  defp block(%{"type" => "image", "data" => data, "mimeType" => mime} = raw, owner, server)
       when is_binary(data) do
    store(data, mime, file_name(raw, mime), owner, server)
  end

  defp block(%{"type" => "audio", "data" => data, "mimeType" => mime} = raw, owner, server)
       when is_binary(data) do
    store(data, mime, file_name(raw, mime), owner, server)
  end

  defp block(%{"type" => "resource", "resource" => resource}, owner, server)
       when is_map(resource) do
    mime = resource["mimeType"] || "application/octet-stream"

    cond do
      is_binary(resource["blob"]) ->
        store(resource["blob"], mime, file_name(resource, mime), owner, server)

      is_binary(resource["text"]) ->
        {:text, resource["text"]}

      true ->
        :skip
    end
  end

  defp block(%{"type" => "resource_link", "uri" => uri} = raw, _owner, _server)
       when is_binary(uri) do
    if String.starts_with?(uri, "http://") or String.starts_with?(uri, "https://") do
      mime = raw["mimeType"] || "application/octet-stream"

      {:output,
       %{
         type: output_type(mime),
         mediaUrl: uri,
         metadata: %{"fileName" => file_name(raw, mime), "mimeType" => mime, "source" => "mcp"}
       }}
    else
      {:text, raw["name"] || uri}
    end
  end

  defp block(_other, _owner, _server), do: :skip

  defp store(base64, mime, name, owner_id, server_name) do
    with {:ok, bytes} <- decode(base64),
         :ok <- check_size(bytes, name),
         {:ok, url} <- put_object(bytes, name, owner_id, server_name) do
      {:output,
       %{
         type: output_type(mime),
         mediaUrl: url,
         metadata: %{
           "fileName" => name,
           "mimeType" => mime,
           "byteCount" => byte_size(bytes),
           "source" => "mcp"
         }
       }}
    else
      {:error, reason} ->
        Logger.warning("[MCP.Content] dropping block name=#{name} reason=#{inspect(reason)}")
        {:text, "(فایل #{name} ساخته شد ولی ذخیره نشد: #{describe(reason)})"}
    end
  end

  defp decode(base64) do
    case Base.decode64(base64, ignore: :whitespace) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_base64}
    end
  end

  defp check_size(bytes, _name) when byte_size(bytes) <= @max_blob_bytes, do: :ok
  defp check_size(_bytes, _name), do: {:error, :too_large}

  defp put_object(bytes, name, owner_id, server_name) do
    ext = Path.extname(name)
    stamp = System.system_time(:millisecond)
    random = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    remote_path = "#{owner_id}/mcp/#{slug(server_name)}-#{stamp}_#{random}#{ext}"

    tmp = Path.join(System.tmp_dir!(), "mcp-#{random}#{ext}")

    try do
      with :ok <- File.write(tmp, bytes),
           {:ok, url} <- Storage.upload(tmp, remote_path, bucket: :media) do
        {:ok, url}
      else
        {:error, reason} -> {:error, reason}
      end
    after
      File.rm(tmp)
    end
  end

  defp file_name(raw, mime) when is_map(raw) do
    raw
    |> Map.get("name")
    |> case do
      name when is_binary(name) and name != "" ->
        Path.basename(name)

      _ ->
        meta = Map.get(raw, "_meta") || %{}

        case Map.get(meta, "fileName") do
          name when is_binary(name) and name != "" -> Path.basename(name)
          _ -> "file-#{System.unique_integer([:positive])}#{extension_for(mime)}"
        end
    end
    |> sanitize_name()
  end

  defp sanitize_name(name) do
    name
    |> String.replace(~r/[^\p{L}\p{N}\.\-_]+/u, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> String.slice(0, 120)
    |> case do
      "" -> "file-#{System.unique_integer([:positive])}"
      value -> value
    end
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> case do
      "" -> "mcp"
      value -> value
    end
  end

  defp extension_for("application/pdf"), do: ".pdf"
  defp extension_for("image/png"), do: ".png"
  defp extension_for("image/jpeg"), do: ".jpg"
  defp extension_for("image/webp"), do: ".webp"
  defp extension_for("text/csv"), do: ".csv"
  defp extension_for("audio/mpeg"), do: ".mp3"
  defp extension_for("audio/ogg"), do: ".ogg"
  defp extension_for(_), do: ""

  defp output_type("image/" <> _), do: "image"
  defp output_type("audio/" <> _), do: "audio"
  defp output_type(_), do: "file"

  defp fallback_text("", [], _result), do: ""

  defp fallback_text("", outputs, _result) do
    names =
      outputs
      |> Enum.map(&get_in(&1, [:metadata, "fileName"]))
      |> Enum.reject(&is_nil/1)

    case names do
      [] -> "فایل آماده شد."
      list -> "فایل آماده شد: #{Enum.join(list, "، ")}"
    end
  end

  defp fallback_text(text, _outputs, _result), do: text

  defp describe(:too_large), do: "حجم بیش از حد مجاز"
  defp describe(:invalid_base64), do: "داده‌ی نامعتبر"
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
