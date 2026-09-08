defmodule VibeAgentsWeb.InternalController do
  @moduledoc "Core → runtime routes under /internal/v1 (spec §3.2), behind InternalServiceAuth."
  use VibeAgentsWeb, :controller
  alias VibeAgents.{Runs, Sandbox}

  def create_run(conn, params), do: start_run(conn, params)

  def provider_invoke(conn, params), do: start_run(conn, Map.put(params, "source", "provider"))

  defp start_run(conn, params) do
    case Runs.start(params) do
      {:ok, run} -> conn |> put_status(202) |> json(%{"runId" => run.id, "status" => run.status})
      {:error, :kill_switch} -> conn |> put_status(503) |> json(%{"error" => "kill_switch"})
      {:error, %Ecto.Changeset{} = changeset} -> conn |> put_status(422) |> json(%{"error" => "invalid_run_request", "details" => changeset_errors(changeset)})
    end
  end

  def cancel_run(conn, %{"run_id" => run_id} = params) do
    case Runs.cancel(run_id, %{"reason" => params["reason"], "requested_by_user_id" => params["requestedByUserId"]}) do
      :ok ->
        run = Runs.get(run_id)
        json(conn, %{"runId" => run_id, "status" => (run && run.status) || "cancelled"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{"error" => "not_found"})
    end
  end

  def decide(conn, %{"run_id" => run_id} = params) do
    case Runs.decide(run_id, params) do
      :ok -> json(conn, %{"ok" => true})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{"error" => "not_found"})
      {:error, :already_decided} -> conn |> put_status(409) |> json(%{"error" => "already_decided"})
      {:error, :expired} -> conn |> put_status(409) |> json(%{"error" => "expired"})
    end
  end

  def show_run(conn, %{"run_id" => run_id}) do
    case Runs.get(run_id) do
      nil -> conn |> put_status(404) |> json(%{"error" => "not_found"})
      run -> json(conn, %{"run" => run_payload(run), "events" => Enum.map(Runs.events_tail(run_id, 200), &event_payload/1)})
    end
  end

  def computer(conn, %{"agent_id" => agent_id, "action" => "ensure"} = params) do
    case Sandbox.ensure_computer(agent_id, params["capabilities"] || %{}) do
      {:ok, computer} -> json(conn, %{"computerId" => computer.sandbox_id, "status" => computer.status})
      {:error, reason} -> conn |> put_status(422) |> json(%{"error" => inspect(reason)})
    end
  end

  def computer(conn, %{"agent_id" => agent_id, "action" => "destroy"}) do
    Sandbox.destroy(agent_id)
    json(conn, %{"computerId" => nil, "status" => "none"})
  end

  def computer(conn, _params), do: conn |> put_status(400) |> json(%{"error" => "action must be ensure or destroy"})

  def computer_preview(conn, %{"agent_id" => agent_id}) do
    case Sandbox.preview(agent_id) do
      {:ok, preview} -> json(conn, preview)
      {:error, reason} -> conn |> put_status(404) |> json(%{"error" => inspect(reason)})
    end
  end

  def computer_session(conn, %{"agent_id" => agent_id} = params),
    do: agent_id |> Sandbox.computer_session(gateway_body(params)) |> passthrough(conn)

  def close_computer_session(conn, %{"agent_id" => agent_id, "session_id" => session_id}),
    do: agent_id |> Sandbox.close_computer_session(session_id) |> passthrough(conn)

  def computer_frame(conn, %{"agent_id" => agent_id} = params),
    do: agent_id |> Sandbox.computer_frame(since_seq(params), params["session"]) |> passthrough(conn)

  def computer_state(conn, %{"agent_id" => agent_id} = params),
    do: agent_id |> Sandbox.computer_state(params["session"]) |> passthrough(conn)

  def computer_exec_log(conn, %{"agent_id" => agent_id} = params),
    do: agent_id |> Sandbox.exec_log(since_seq(params), int_param(params["limit"], 40)) |> passthrough(conn)

  def computer_tree(conn, %{"agent_id" => agent_id} = params),
    do: agent_id |> Sandbox.tree(params["path"], int_param(params["depth"], 2)) |> passthrough(conn)

  def computer_file(conn, %{"agent_id" => agent_id, "path" => path}),
    do: agent_id |> Sandbox.read_file(path) |> passthrough(conn)

  def computer_control(conn, %{"agent_id" => agent_id} = params),
    do: agent_id |> Sandbox.computer_control(gateway_body(params)) |> passthrough(conn)

  def computer_input(conn, %{"agent_id" => agent_id} = params),
    do: agent_id |> Sandbox.computer_input(gateway_body(params)) |> passthrough(conn)

  def browser_navigate(conn, %{"agent_id" => agent_id} = params),
    do: agent_id |> Sandbox.browser_navigate(gateway_body(params)) |> passthrough(conn)

  def browser_action(conn, %{"agent_id" => agent_id} = params),
    do: agent_id |> Sandbox.browser_action(gateway_body(params)) |> passthrough(conn)

  def browser_screenshot(conn, %{"agent_id" => agent_id} = params),
    do: agent_id |> Sandbox.browser_screenshot(int_param(params["maxWidth"], 1024)) |> passthrough(conn)

  defp passthrough({:ok, :no_change}, conn), do: send_resp(conn, 204, "")
  defp passthrough({:ok, body}, conn), do: json(conn, body)
  defp passthrough({:error, {:http_error, status, body}}, conn), do: conn |> put_status(status) |> json(error_body(body))
  defp passthrough({:error, :not_available}, conn), do: conn |> put_status(404) |> json(%{"error" => "not_available"})
  defp passthrough({:error, :not_configured}, conn), do: conn |> put_status(503) |> json(%{"error" => "not_configured"})
  defp passthrough({:error, reason}, conn), do: conn |> put_status(502) |> json(%{"error" => inspect(reason)})

  defp error_body(body) when is_map(body), do: body

  defp error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> decoded
      _ -> %{"error" => body}
    end
  end

  defp error_body(body), do: %{"error" => inspect(body)}

  defp gateway_body(params), do: Map.drop(params, ["agent_id", "session_id"])

  defp since_seq(%{"since" => since}) when is_integer(since) and since >= 0, do: since

  defp since_seq(%{"since" => since}) when is_binary(since) do
    case Integer.parse(since) do
      {seq, _rest} when seq >= 0 -> seq
      _ -> 0
    end
  end

  defp since_seq(_params), do: 0

  defp int_param(value, _default) when is_integer(value) and value >= 0, do: value

  defp int_param(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp int_param(_value, default), do: default

  @doc """
  `VibeAgents.Voice.Sessions` is the voice worker's module — resolved dynamically via
  `apply/3` so a missing module is a runtime 503, never a compile-time dependency.
  """
  def voice_sessions(conn, params) do
    if Code.ensure_loaded?(VibeAgents.Voice.Sessions) and function_exported?(VibeAgents.Voice.Sessions, :create, 1) do
      case apply(VibeAgents.Voice.Sessions, :create, [params]) do
        {:ok, session} -> json(conn, session)
        {:error, reason} -> conn |> put_status(422) |> json(%{"error" => inspect(reason)})
      end
    else
      conn |> put_status(503) |> json(%{"error" => "voice_unavailable"})
    end
  end

  def healthz(conn, _params), do: json(conn, %{"ok" => true})

  defp run_payload(run) do
    %{
      "id" => run.id,
      "agentId" => run.agent_id,
      "agentUserId" => run.agent_user_id,
      "ownerUserId" => run.owner_user_id,
      "requesterUserId" => run.requester_user_id,
      "chatId" => run.chat_id,
      "status" => run.status,
      "steps" => run.steps,
      "costCents" => run.cost_cents,
      "usage" => run.usage,
      "error" => run.error,
      "result" => run.result,
      "startedAt" => run.started_at,
      "finishedAt" => run.finished_at
    }
  end

  defp event_payload(event), do: %{"seq" => event.seq, "kind" => event.kind, "payload" => event.payload, "ts" => event.ts}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
