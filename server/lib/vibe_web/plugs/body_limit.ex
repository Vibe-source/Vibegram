defmodule VibeWeb.Plugs.BodyLimit do
  @moduledoc """
  Rejects a request whose declared `content-length` exceeds `max_bytes:`,
  before `Plug.Parsers` ever starts reading/buffering the body.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    max_bytes = Keyword.fetch!(opts, :max_bytes)

    case declared_length(conn) do
      bytes when is_integer(bytes) and bytes > max_bytes ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(413, Jason.encode!(%{error: "payload_too_large"}))
        |> halt()

      _ ->
        conn
    end
  end

  defp declared_length(conn) do
    case get_req_header(conn, "content-length") do
      [value] ->
        case Integer.parse(value) do
          {bytes, _} -> bytes
          :error -> nil
        end

      _ ->
        nil
    end
  end
end
