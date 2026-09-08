defmodule VibeAgents.Test.FakeCoreHTTP do
  @moduledoc """
  Stand-in for `VibeAgents.CoreClient.Finch` (config `:core_http`). Records every request in
  an ETS table and answers the core's internal routes with canned bodies.
  """

  @table :fake_core_http_calls

  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  def calls do
    ensure_table()
    @table |> :ets.tab2list() |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
  end

  def calls_to(path_suffix) do
    Enum.filter(calls(), fn %{path: path} -> String.ends_with?(path, path_suffix) end)
  end

  def request(method, url, body, headers) do
    ensure_table()
    path = url |> URI.parse() |> Map.get(:path)
    decoded = if body in [nil, ""], do: %{}, else: Jason.decode!(body)
    :ets.insert(@table, {System.unique_integer([:monotonic]), %{method: method, path: path, body: decoded, headers: headers}})
    respond(path, decoded)
  end

  defp respond("/internal/v1/provider-auth", %{"identifier" => identifier, "secret" => "good-secret"}) do
    {:ok,
     %{
       status: 200,
       body:
         Jason.encode!(%{
           "agentProfile" => %{
             "displayName" => "Fake Agent",
             "username" => identifier,
             "modelProvider" => "anthropic",
             "modelId" => "claude-sonnet-5",
             "enabledTools" => ["search_google"],
             "autonomyMode" => "safe_auto"
           },
           "agentId" => "11111111-1111-1111-1111-111111111111",
           "agentUserId" => "22222222-2222-2222-2222-222222222222",
           "ownerUserId" => "33333333-3333-3333-3333-333333333333",
           "defaultChatId" => "chat-default"
         })
     }}
  end

  defp respond("/internal/v1/provider-auth", %{"secret" => "other-secret"}) do
    {:ok,
     %{
       status: 200,
       body:
         Jason.encode!(%{
           "agentProfile" => %{"displayName" => "Other", "username" => "other", "modelProvider" => "anthropic", "modelId" => "claude-sonnet-5", "enabledTools" => [], "autonomyMode" => "safe_auto"},
           "agentId" => "44444444-4444-4444-4444-444444444444",
           "agentUserId" => "55555555-5555-5555-5555-555555555555",
           "ownerUserId" => "66666666-6666-6666-6666-666666666666",
           "defaultChatId" => "chat-other"
         })
     }}
  end

  defp respond("/internal/v1/provider-auth", _body), do: {:ok, %{status: 401, body: Jason.encode!(%{"error" => "unauthorized"})}}
  defp respond("/internal/v1/agent-events", %{"events" => events}), do: {:ok, %{status: 200, body: Jason.encode!(%{"accepted" => length(events)})}}
  defp respond("/internal/v1/deliveries", _body), do: {:ok, %{status: 200, body: Jason.encode!(%{"deliveries" => [%{"messageId" => "m1"}]})}}
  defp respond("/internal/v1/approvals", _body), do: {:ok, %{status: 200, body: Jason.encode!(%{"taskId" => "t1", "messageId" => "m2"})}}
  defp respond("/internal/v1/handoffs", _body), do: {:ok, %{status: 200, body: Jason.encode!(%{"messageId" => "m3", "dispatched" => true})}}
  defp respond(_path, _body), do: {:ok, %{status: 404, body: Jason.encode!(%{"error" => "not_found"})}}

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
