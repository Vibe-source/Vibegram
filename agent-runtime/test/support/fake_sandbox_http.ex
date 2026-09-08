defmodule VibeAgents.Test.FakeSandboxHTTP do
  @moduledoc "Stand-in for `VibeAgents.Sandbox.Client.Finch` (config `:sandbox_http`)."

  @table :fake_sandbox_http_calls

  @doc "Answers every request with `fun.(method, url, body)`; `reset/0` restores the canned replies."
  def stub(fun) when is_function(fun, 3), do: Application.put_env(:vibe_agents, :fake_sandbox_responder, fun)

  def reset do
    Application.delete_env(:vibe_agents, :fake_sandbox_responder)
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  def calls do
    ensure_table()
    @table |> :ets.tab2list() |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
  end

  def request(method, url, body, _headers, _timeout) do
    record(method, url, body)

    case Application.get_env(:vibe_agents, :fake_sandbox_responder) do
      fun when is_function(fun, 3) -> fun.(method, url, body)
      _ -> canned(method, url, body)
    end
  end

  defp record(method, url, body) do
    ensure_table()
    :ets.insert(@table, {System.unique_integer([:monotonic]), %{method: method, url: url, body: body}})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp canned(:post, url, body) do
    cond do
      String.ends_with?(url, "/v1/sandboxes") ->
        {:ok, %{"id" => "vibe-sb-test", "status" => "running", "createdAt" => 0}}

      String.contains?(url, "/exec") ->
        {:ok, %{"exitCode" => 0, "stdout" => "ran: #{body["cmd"] |> List.wrap() |> Enum.join(" ")}", "stderr" => "", "truncated" => false, "durationMs" => 1}}

      true ->
        {:ok, %{"ok" => true}}
    end
  end

  defp canned(_method, _url, _body), do: {:ok, %{"ok" => true}}

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:named_table, :public, :set])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
