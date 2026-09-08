defmodule VibeAgentsWeb.ProviderController do
  @moduledoc """
  Public provider ingress `/v1/*` (spec §3.5). Auth via `x-vibe-agent-secret` or `Authorization:
  Bearer` — the runtime never stores agent secrets, it calls `CoreClient.provider_auth/2`.
  """
  use VibeAgentsWeb, :controller
  alias VibeAgents.{CoreClient, Runs}

  @reply_wait_ms 25_000

  def invoke(conn, %{"identifier" => identifier} = params) do
    with {:ok, secret} <- fetch_secret(conn),
         {:ok, auth} <- CoreClient.provider_auth(identifier, secret) do
      run_id = params["runId"] || Ecto.UUID.generate()
      response_mode = params["responseMode"] || "async"

      if response_mode == "reply", do: Phoenix.PubSub.subscribe(VibeAgents.PubSub, "run:" <> run_id)

      run_request = %{
        "runId" => run_id,
        "idempotencyKey" => idempotency_key(conn, params),
        "source" => "provider",
        "agentId" => auth["agentId"],
        "agentUserId" => auth["agentUserId"],
        "ownerUserId" => auth["ownerUserId"],
        "chatId" => params["chatId"] || auth["defaultChatId"],
        "chatKind" => params["chatKind"] || "dm",
        "input" => params["input"] || %{"text" => params["text"] || ""},
        "agentProfile" => auth["agentProfile"] || %{},
        "context" => params["context"] || %{},
        "capabilities" => params["capabilities"] || %{}
      }

      dispatch(conn, run_request, response_mode)
    else
      {:error, :missing_secret} -> conn |> put_status(401) |> json(%{"error" => "missing_secret"})
      {:error, _reason} -> conn |> put_status(401) |> json(%{"error" => "unauthorized"})
    end
  end

  defp dispatch(conn, run_request, response_mode) do
    case Runs.start(run_request) do
      {:ok, run} when response_mode == "reply" -> await_reply(conn, run)
      {:ok, run} -> conn |> put_status(202) |> json(%{"taskId" => run.id, "status" => run.status})
      {:error, :kill_switch} -> conn |> put_status(503) |> json(%{"error" => "kill_switch"})
      {:error, %Ecto.Changeset{}} -> conn |> put_status(422) |> json(%{"error" => "invalid_request"})
    end
  end

  def events(conn, %{"identifier" => identifier} = params) do
    with {:ok, secret} <- fetch_secret(conn),
         {:ok, _auth} <- CoreClient.provider_auth(identifier, secret) do
      json(conn, %{"ok" => true, "eventId" => params["eventId"] || Ecto.UUID.generate()})
    else
      _ -> conn |> put_status(401) |> json(%{"error" => "unauthorized"})
    end
  end

  def card(conn, %{"identifier" => identifier}) do
    case CoreClient.card(identifier) do
      {:ok, card} -> json(conn, rewrite_url(card))
      {:error, _reason} -> conn |> put_status(404) |> json(%{"error" => "not_found"})
    end
  end

  def task(conn, %{"task_id" => task_id}) do
    with {:ok, secret} <- fetch_secret(conn),
         run when not is_nil(run) <- Runs.get(task_id),
         {:ok, %{"agentId" => agent_id}} <- CoreClient.provider_auth(run.agent_id, secret),
         true <- agent_id == run.agent_id do
      json(conn, %{"taskId" => run.id, "status" => run.status, "outputs" => outputs(run)})
    else
      nil -> conn |> put_status(404) |> json(%{"error" => "not_found"})
      _ -> conn |> put_status(401) |> json(%{"error" => "unauthorized"})
    end
  end

  defp await_reply(conn, run) do
    receive do
      {:run_event, %{"kind" => "run.completed"}} ->
        run = Runs.get(run.id)
        json(conn, %{"taskId" => run.id, "status" => run.status, "outputs" => outputs(run)})

      {:run_event, %{"kind" => "run.failed"} = event} ->
        conn |> put_status(502) |> json(%{"taskId" => run.id, "status" => "failed", "error" => get_in(event, ["payload", "error"])})
    after
      @reply_wait_ms -> conn |> put_status(202) |> json(%{"taskId" => run.id, "status" => run.status})
    end
  end

  defp outputs(%{result: %{"text" => text}}) when is_binary(text), do: [%{"type" => "text", "text" => text}]
  defp outputs(_run), do: []

  defp fetch_secret(conn) do
    case get_req_header(conn, "x-vibe-agent-secret") do
      [value | _] when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        case get_req_header(conn, "authorization") do
          ["Bearer " <> token] when token != "" -> {:ok, token}
          _ -> {:error, :missing_secret}
        end
    end
  end

  defp idempotency_key(conn, params) do
    case get_req_header(conn, "idempotency-key") do
      [value | _] -> value
      _ -> params["eventId"]
    end
  end

  defp rewrite_url(card) when is_map(card) do
    case Application.get_env(:vibe_agents, :public_url) do
      nil -> card
      base -> Map.put(card, "url", base)
    end
  end

  defp rewrite_url(card), do: card
end
