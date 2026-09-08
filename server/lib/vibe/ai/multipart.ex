defmodule Vibe.AI.Multipart do
  @moduledoc """
  Minimal `multipart/form-data` encoder.
  """

  @type field :: {String.t(), String.t()}
  @type file :: {String.t(), {:file, String.t(), String.t(), binary()}}
  @type part :: field | file

  @doc """
  Encodes `parts` into `{content_type, body}`.
  """
  @spec encode([part]) :: {String.t(), binary()}
  def encode(parts) when is_list(parts) do
    boundary = "----VibeBoundary" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))

    body =
      parts
      |> Enum.map(&encode_part(&1, boundary))
      |> IO.iodata_to_binary()

    {"multipart/form-data; boundary=#{boundary}", body <> "--#{boundary}--\r\n"}
  end

  defp encode_part({name, {:file, filename, content_type, bytes}}, boundary) do
    [
      "--#{boundary}\r\n",
      ~s(content-disposition: form-data; name="#{name}"; filename="#{escape(filename)}"\r\n),
      "content-type: #{content_type}\r\n\r\n",
      bytes,
      "\r\n"
    ]
  end

  defp encode_part({name, value}, boundary) do
    [
      "--#{boundary}\r\n",
      ~s(content-disposition: form-data; name="#{name}"\r\n\r\n),
      to_string(value),
      "\r\n"
    ]
  end

  # Quotes and CR/LF in a filename would break out of the header line.
  defp escape(filename) do
    filename
    |> String.replace(~r/[\r\n"]/, "_")
    |> String.slice(0, 200)
  end
end
