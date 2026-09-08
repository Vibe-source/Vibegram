defmodule VibeAgents.Sandbox.Client do
  @moduledoc "HTTP client for the sandbox-gateway (spec §3.6), header `x-sandbox-token`."
  require Logger

  @timeout 30_000
  @exec_timeout 250_000
  # Gateway browser calls wait up to SANDBOX_BROWSER_TIMEOUT_MS (default 90.
  @browser_timeout 120_000

  def configured?, do: not is_nil(base_url()) and not is_nil(token())

  def create_sandbox(body), do: post("/v1/sandboxes", body)
  def get_sandbox(id), do: get("/v1/sandboxes/#{id}")
  def exec(id, body), do: post("/v1/sandboxes/#{id}/exec", body, @exec_timeout)
  def exec_log(id, since, limit), do: get(with_query("/v1/sandboxes/#{id}/exec/log", since: since, limit: limit))
  def write_file(id, body), do: put("/v1/sandboxes/#{id}/files", body)
  def read_file(id, path), do: get("/v1/sandboxes/#{id}/files?path=#{URI.encode_www_form(path)}")
  def tree(id, path, depth), do: get("/v1/sandboxes/#{id}/tree?path=#{URI.encode_www_form(path || "")}&depth=#{depth || 2}")
  def browser_navigate(id, body), do: post("/v1/sandboxes/#{id}/browser/navigate", body, @browser_timeout)
  def browser_action(id, body), do: post("/v1/sandboxes/#{id}/browser/action", body, @browser_timeout)

  def browser_read(id), do: request(:get, "/v1/sandboxes/#{id}/browser/read", nil, @browser_timeout)

  def browser_screenshot(id, max_width \\ 1024),
    do: request(:get, "/v1/sandboxes/#{id}/browser/screenshot?maxWidth=#{max_width}", nil, @browser_timeout)
  def stop(id), do: post("/v1/sandboxes/#{id}/stop", %{})
  def delete(id), do: delete_request("/v1/sandboxes/#{id}")

  def computer_session(id, body), do: post("/v1/sandboxes/#{id}/computer/session", body)

  def close_computer_session(id, session_id),
    do: delete_request("/v1/sandboxes/#{id}/computer/session/#{URI.encode_www_form(session_id)}")

  def computer_frame(id, since \\ 0, session \\ nil),
    do: get(with_query("/v1/sandboxes/#{id}/computer/frame", since: since, session: session))

  def computer_state(id, session \\ nil),
    do: get(with_query("/v1/sandboxes/#{id}/computer/state", session: session))

  def computer_control(id, body), do: post("/v1/sandboxes/#{id}/computer/control", body)
  def computer_input(id, body), do: post("/v1/sandboxes/#{id}/computer/input", body)

  defp with_query(path, pairs) do
    case pairs |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> URI.encode_query() do
      "" -> path
      query -> path <> "?" <> query
    end
  end

  defp get(path), do: request(:get, path, nil, @timeout)
  defp post(path, body, timeout \\ @timeout), do: request(:post, path, body, timeout)
  defp put(path, body), do: request(:put, path, body, @timeout)
  defp delete_request(path), do: request(:delete, path, nil, @timeout)

  defp request(method, path, body, timeout) do
    if configured?() do
      http_module().request(method, base_url() <> path, body, [{"x-sandbox-token", token()}], timeout)
    else
      {:error, :not_configured}
    end
  end

  defp http_module, do: Application.get_env(:vibe_agents, :sandbox_http, __MODULE__.Finch)
  defp base_url, do: Application.get_env(:vibe_agents, :sandbox_gateway_url)
  defp token, do: Application.get_env(:vibe_agents, :sandbox_gateway_token)

  defmodule Finch do
    @moduledoc "Default HTTP transport for VibeAgents.Sandbox.Client — real Finch requests."

    def request(method, url, body, headers, timeout) do
      json_headers = [{"content-type", "application/json"} | headers]
      encoded = if is_nil(body), do: "", else: Jason.encode!(body)
      req = Elixir.Finch.build(method, url, json_headers, encoded)

      case Elixir.Finch.request(req, VibeAgents.Finch, receive_timeout: timeout) do
        {:ok, %{status: 204}} ->
          {:ok, :no_change}

        {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
          case Jason.decode(resp_body) do
            {:ok, decoded} -> {:ok, decoded}
            {:error, _} -> {:ok, %{}}
          end

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:http_error, status, String.slice(resp_body, 0, 300)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
