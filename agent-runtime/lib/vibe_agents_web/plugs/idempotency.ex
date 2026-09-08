defmodule VibeAgentsWeb.Plugs.Idempotency do
  @moduledoc "ETS, 24h: replays the first response for a repeated Idempotency-Key or body eventId."
  import Plug.Conn

  @behaviour Plug
  @table :vibe_agents_idempotency
  @ttl_ms 24 * 60 * 60 * 1000

  def init(opts), do: opts

  def call(conn, _opts) do
    ensure_table()

    case key(conn) do
      nil -> conn
      key -> serve(conn, key)
    end
  end

  defp serve(conn, key) do
    sweep()

    case :ets.lookup(@table, key) do
      [{^key, status, body, _expires_at}] ->
        conn |> put_resp_content_type("application/json") |> send_resp(status, body) |> halt()

      [] ->
        register_before_send(conn, fn conn ->
          :ets.insert(@table, {key, conn.status, resp_body(conn), System.system_time(:millisecond) + @ttl_ms})
          conn
        end)
    end
  end

  defp resp_body(%{resp_body: body}) when is_binary(body) or is_list(body), do: IO.iodata_to_binary(body)
  defp resp_body(_conn), do: ""

  defp key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [value | _] when is_binary(value) and value != "" -> value
      _ -> event_id(conn)
    end
  end

  defp event_id(conn) do
    case conn.body_params do
      %{"eventId" => id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp sweep do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
