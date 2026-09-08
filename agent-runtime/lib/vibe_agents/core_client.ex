defmodule VibeAgents.CoreClient do
  @moduledoc """
  Signed requests to the core's `/internal/v1/*` (spec §3.3), `vibe-internal-auth/v1`.
  10s timeout, one retry on 5xx/timeout for idempotent calls (send_events/deliver skip retry
  on error — the caller's own outbox/at-least-once semantics already cover that).
  """
  require Logger

  def send_events(events) when is_list(events), do: post("/internal/v1/agent-events", %{"events" => events}, retry?: false)
  def deliver(body) when is_map(body), do: post("/internal/v1/deliveries", body, retry?: false)
  def request_approval(body) when is_map(body), do: post("/internal/v1/approvals", body, retry?: true)
  def handoff(body) when is_map(body), do: post("/internal/v1/handoffs", body, retry?: true)

  def provider_auth(identifier, secret) do
    post("/internal/v1/provider-auth", %{"identifier" => identifier, "secret" => secret}, retry?: true)
  end

  def card(agent_id), do: get("/internal/v1/agents/#{agent_id}/card")

  defp post(path, body, opts) do
    encoded = Jason.encode!(body)
    request("POST", path, encoded, Keyword.get(opts, :retry?, false))
  end

  defp get(path), do: request("GET", path, "", false)

  defp request(method, path, body, retry?) do
    case classify(do_request(method, path, body)) do
      {:retry, first_reason} when retry? ->
        Process.sleep(250)

        case classify(do_request(method, path, body)) do
          {:ok, resp} -> decode(resp)
          {:retry, _second_reason} -> {:error, first_reason}
          {:error, reason} -> {:error, reason}
        end

      {:retry, reason} ->
        {:error, reason}

      {:ok, resp} ->
        decode(resp)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classify({:ok, %{status: status} = resp}) when status in 200..299, do: {:ok, resp}
  defp classify({:ok, %{status: status}}) when status >= 500, do: {:retry, {:http_error, status}}
  defp classify({:ok, %{status: status}}), do: {:error, {:http_error, status}}
  defp classify({:error, reason}), do: {:retry, reason}

  defp decode(%{body: ""}), do: {:ok, %{}}

  defp decode(%{body: body}) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, %{}}
    end
  end

  defp do_request(method, path, body) do
    http_module().request(method, base_url() <> path, body, sign(method, path, body))
  end

  defp sign(method, path, body) do
    key = hmac_key()
    headers = VibeContracts.ServiceAuth.sign(key, method, path, body, service: "agent-runtime")

    case headers do
      %{} = h -> Map.to_list(h) ++ [{"content-type", "application/json"}]
      _ -> [{"content-type", "application/json"}]
    end
  end

  defp http_module, do: Application.get_env(:vibe_agents, :core_http, __MODULE__.Finch)
  defp base_url, do: Application.get_env(:vibe_agents, :core_internal_url) || ""
  defp hmac_key, do: Application.get_env(:vibe_agents, :internal_hmac_key) || ""

  defmodule Finch do
    @moduledoc "Default HTTP transport for VibeAgents.CoreClient — real Finch requests."

    def request(_method, url, _body, _headers) when not is_binary(url), do: {:error, :core_url_unset}

    def request(method, url, body, headers) do
      if URI.parse(url).scheme == nil do
        {:error, :core_url_unset}
      else
        do_request(method, url, body, headers)
      end
    end

    defp do_request(method, url, body, headers) do
      req = Elixir.Finch.build(String.to_existing_atom(String.downcase(method)), url, headers, body)

      case Elixir.Finch.request(req, VibeAgents.Finch, receive_timeout: 10_000) do
        {:ok, %{status: status, body: resp_body}} -> {:ok, %{status: status, body: resp_body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
