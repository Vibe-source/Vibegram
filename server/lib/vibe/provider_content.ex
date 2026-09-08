defmodule Vibe.ProviderContent do
  @moduledoc """
  Validator and degrader for the frozen `vibe.content.v1` provider content contract.
  """

  @contract_id "vibe.content.v1"
  @core_kinds ~w(text media card actions status citations error)

  @type parse_error ::
          :invalid_content
          | {:invalid_content, atom()}

  @doc """
  Validate and normalize a decoded JSON `content` envelope.
  """
  @spec parse(term()) :: {:ok, map()} | {:error, parse_error()}
  def parse(term) when not is_map(term), do: {:error, :invalid_content}

  def parse(content) when is_map(content) do
    with :ok <- validate_contract(content),
         {:ok, fallback} <- require_nonempty_string(content, "fallbackText", :missing_fallback_text),
         {:ok, parts_in} <- require_parts_list(content),
         {:ok, parts} <- normalize_parts(parts_in) do
      normalized =
        content
        |> stringify_keys()
        |> Map.put("contract", @contract_id)
        |> Map.put("fallbackText", fallback)
        |> Map.put("parts", parts)

      {:ok, normalized}
    end
  end

  @doc """
  Degrade a normalized content envelope to today's message attrs.
  """
  @spec to_message_attrs(map()) :: map()
  def to_message_attrs(normalized) when is_map(normalized) do
    parts = Map.get(normalized, "parts") || Map.get(normalized, :parts) || []
    fallback = get_str(normalized, "fallbackText") || ""

    body =
      parts
      |> Enum.reject(&(part_kind(&1) == "status"))
      |> Enum.map(&get_str(&1, "text"))
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> case do
        [] -> fallback
        texts -> Enum.join(texts, "\n\n")
      end

    attachments =
      parts
      |> Enum.filter(&(part_kind(&1) == "media"))
      |> Enum.map(&media_attachment/1)
      |> Enum.reject(&is_nil/1)

    %{"text" => body, "attachments" => attachments}
  end

  @doc """
  Server-supported content-contract descriptor for agent-card negotiation.
  """
  @spec capabilities() :: map()
  def capabilities do
    %{
      "version" => 1,
      "parts" => @core_kinds,
      "ext" => ["vibe.call"]
    }
  end

  @doc """
  Realtime-voice capability descriptor for agent-card negotiation.
  """
  @spec realtime_voice_capability(map() | struct()) :: map()
  def realtime_voice_capability(agent) when is_map(agent) do
    modes = output_modes_from_agent(agent)

    %{
      "available" => "voice" in modes,
      "mode" => "callback"
    }
  end

  def realtime_voice_capability(_),
    do: %{"available" => false, "mode" => "callback"}

  defp output_modes_from_agent(agent) when is_map(agent) do
    modes =
      Map.get(agent, :output_modes) ||
        Map.get(agent, "output_modes") ||
        Map.get(agent, :outputModes) ||
        Map.get(agent, "outputModes")

    if is_list(modes), do: modes, else: []
  end


  defp validate_contract(content) do
    case get_str(content, "contract") do
      @contract_id -> :ok
      _ -> {:error, {:invalid_content, :unknown_contract}}
    end
  end

  defp require_parts_list(content) do
    case get_raw(content, "parts") do
      parts when is_list(parts) -> {:ok, parts}
      _ -> {:error, {:invalid_content, :parts_not_list}}
    end
  end

  defp require_nonempty_string(map, key, reason) do
    case get_str(map, key) do
      nil -> {:error, {:invalid_content, reason}}
      "" -> {:error, {:invalid_content, reason}}
      value -> {:ok, value}
    end
  end

  defp normalize_parts(parts) do
    parts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {part, _idx}, {:ok, acc} ->
      case normalize_part(part) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp normalize_part(part) when not is_map(part) do
    {:error, {:invalid_content, :invalid_part}}
  end

  defp normalize_part(part) do
    kind = get_str(part, "kind")

    cond do
      is_nil(kind) or kind == "" ->
        {:error, {:invalid_content, :missing_part_kind}}

      true ->
        case require_nonempty_string(part, "text", :missing_part_text) do
          {:ok, text} ->
            base = stringify_keys(part)

            normalized =
              base
              |> Map.put("kind", kind)
              |> Map.put("text", text)
              |> Map.put("schemaVersion", normalize_schema_version(get_raw(part, "schemaVersion")))
              |> Map.put("required", normalize_required(get_raw(part, "required")))
              |> maybe_trim_string_field("mediaType")
              |> maybe_trim_string_field("url")
              |> maybe_normalize_data()
              |> maybe_normalize_ext()

            {:ok, normalized}

          {:error, _} = err ->
            err
        end
    end
  end

  defp normalize_schema_version(v) when is_integer(v), do: v
  defp normalize_schema_version(_), do: 1

  defp normalize_required(true), do: true
  defp normalize_required(_), do: false

  defp maybe_trim_string_field(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> Map.put(map, key, String.trim(value))
      _ -> map
    end
  end

  defp maybe_normalize_data(map) do
    case Map.get(map, "data") do
      data when is_map(data) -> Map.put(map, "data", stringify_keys(data))
      _ -> map
    end
  end

  defp maybe_normalize_ext(map) do
    case Map.get(map, "ext") do
      ext when is_map(ext) -> Map.put(map, "ext", stringify_keys(ext))
      _ -> map
    end
  end


  defp part_kind(part) when is_map(part), do: get_str(part, "kind")
  defp part_kind(_), do: nil

  defp media_attachment(part) when is_map(part) do
    data = Map.get(part, "data") || Map.get(part, :data) || %{}
    data = if is_map(data), do: data, else: %{}

    media_type =
      get_str(part, "mediaType") ||
        get_str(data, "mediaType") ||
        get_str(data, "mimeType")

    url = get_str(part, "url") || get_str(data, "url")

    caption =
      get_str(data, "caption") ||
        get_str(part, "caption") ||
        get_str(part, "text")

    file_name =
      get_str(data, "fileName") ||
        get_str(data, "filename") ||
        get_str(part, "fileName") ||
        get_str(part, "filename")

    %{
      "mediaType" => media_type,
      "mimeType" => media_type,
      "url" => url,
      "caption" => caption,
      "fileName" => file_name,
      "name" => file_name
    }
    |> put_inferred_type(media_type, url)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp media_attachment(_), do: nil

  defp put_inferred_type(attachment, media_type, url) do
    case infer_attachment_type(media_type, url) do
      nil -> attachment
      type -> Map.put(attachment, "type", type)
    end
  end

  defp infer_attachment_type(media_type, url) do
    lowered_mime = media_type |> to_string() |> String.downcase()
    lowered_url = url |> to_string() |> String.downcase()

    cond do
      lowered_mime == "" and lowered_url == "" ->
        nil

      String.starts_with?(lowered_mime, "image/gif") or
          String.match?(lowered_url, ~r/\.gif(\?|$)/) ->
        "gif"

      String.starts_with?(lowered_mime, "image/") or
          String.match?(lowered_url, ~r/\.(png|jpe?g|webp|heic|bmp)(\?|$)/) ->
        "image"

      String.starts_with?(lowered_mime, "video/") or
          String.match?(lowered_url, ~r/\.(mp4|mov|m4v|webm|mkv)(\?|$)/) ->
        "video"

      String.starts_with?(lowered_mime, "audio/") or
          String.match?(lowered_url, ~r/\.(mp3|m4a|aac|wav|ogg|oga|flac)(\?|$)/) ->
        "music"

      true ->
        "file"
    end
  end


  defp get_raw(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, known_atom(key))
    end
  end

  defp get_str(map, key) when is_map(map) do
    case get_raw(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp get_str(_, _), do: nil

  defp known_atom("contract"), do: :contract
  defp known_atom("fallbackText"), do: :fallbackText
  defp known_atom("parts"), do: :parts
  defp known_atom("kind"), do: :kind
  defp known_atom("text"), do: :text
  defp known_atom("schemaVersion"), do: :schemaVersion
  defp known_atom("required"), do: :required
  defp known_atom("mediaType"), do: :mediaType
  defp known_atom("url"), do: :url
  defp known_atom("caption"), do: :caption
  defp known_atom("fileName"), do: :fileName
  defp known_atom("filename"), do: :filename
  defp known_atom("mimeType"), do: :mimeType
  defp known_atom("data"), do: :data
  defp known_atom("ext"), do: :ext
  defp known_atom(_), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
      {k, v} -> {to_string(k), v}
    end)
  end
end
