defmodule Vibe.Audit do
  @moduledoc """
  Append-only security audit trail. `record/3` never raises — a logging failure must never
  break the caller's actual request.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Vibe.Repo
  alias Vibe.Schemas.AuditEvent

  @doc """
  Records one audit event. `conn_or_nil` is a `Plug.Conn` (its ip/user-agent are captured) or
  `nil` when called from a context with no request.
  """
  def record(conn_or_nil, action, opts \\ []) do
    attrs = %{
      actor_user_id: Keyword.get(opts, :actor_user_id),
      action: to_string(action),
      target_type: Keyword.get(opts, :target_type),
      target_id: opts |> Keyword.get(:target_id) |> maybe_to_string(),
      metadata: Keyword.get(opts, :metadata, %{}),
      ip: request_ip(conn_or_nil),
      user_agent: request_user_agent(conn_or_nil)
    }

    case %AuditEvent{} |> AuditEvent.changeset(attrs) |> Repo.insert() do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.warning("[Audit] rejected action=#{action} errors=#{inspect(changeset.errors)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("[Audit] record failed action=#{action} error=#{inspect(error)}")
      :ok
  end

  @doc "Deletes audit rows older than `days`. Returns the number of rows deleted."
  def prune(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    {count, _} = Repo.delete_all(from(e in AuditEvent, where: e.inserted_at < ^cutoff))
    count
  end

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value), do: to_string(value)

  defp request_ip(%Plug.Conn{remote_ip: ip}) when is_tuple(ip) do
    ip |> :inet.ntoa() |> to_string()
  rescue
    _ -> nil
  end

  defp request_ip(_), do: nil

  defp request_user_agent(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      _ -> nil
    end
  end

  defp request_user_agent(_), do: nil
end
