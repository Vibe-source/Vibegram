defmodule VibeAgents.Sandbox do
  @moduledoc "One sandbox per agent, lazily created through the gateway (spec §3.6)."
  alias VibeAgents.Repo
  alias VibeAgents.Sandbox.Client
  alias VibeAgents.Schemas.AgentComputer

  @default_image "vibe-sandbox:latest"

  @doc "Creates (or reuses) the one sandbox for `agent_id`. {:error, :not_configured} when the gateway is unset."
  def ensure_computer(agent_id, capabilities \\ %{}) do
    if Client.configured?() do
      case running(agent_id) do
        {:ok, computer} -> touch(computer)
        :none -> locked_create(agent_id, capabilities)
      end
    else
      {:error, :not_configured}
    end
  end

  # Two tools in one round both reach for the computer.
  defp locked_create(agent_id, capabilities) do
    lock = {{:vibe_sandbox, agent_id}, self()}

    case :global.trans(lock, fn ->
           case running(agent_id) do
             {:ok, computer} -> touch(computer)
             :none -> create(agent_id, capabilities, Repo.get_by(AgentComputer, agent_id: agent_id))
           end
         end) do
      :aborted -> {:error, :sandbox_lock_unavailable}
      result -> result
    end
  end

  @doc "Turns a gateway failure into a sentence the agent can act on, not an inspect dump."
  def describe_error(:not_configured), do: "the sandbox gateway is not configured"

  def describe_error({:http_error, 409, _body}),
    do: "every computer is busy right now — wait a few seconds and try the same call again"

  def describe_error({:http_error, status, _body}), do: "the gateway answered #{status}"
  def describe_error(:sandbox_lock_unavailable), do: "another step is still starting the computer"
  def describe_error(reason), do: inspect(reason)

  defp running(agent_id) do
    case Repo.get_by(AgentComputer, agent_id: agent_id) do
      %AgentComputer{sandbox_id: id, status: "running"} = computer when is_binary(id) -> {:ok, computer}
      _ -> :none
    end
  end

  defp create(agent_id, capabilities, existing) do
    network = if (capabilities["network"] || capabilities[:network]) == "none", do: "none", else: "proxy"
    owner_key = "agent:#{agent_id}"

    case Client.create_sandbox(%{"ownerKey" => owner_key, "image" => @default_image, "network" => network}) do
      {:ok, %{"id" => sandbox_id, "status" => status}} ->
        record = existing || %AgentComputer{}

        record
        |> AgentComputer.changeset(%{
          agent_id: agent_id,
          sandbox_id: sandbox_id,
          status: status || "running",
          image: @default_image,
          last_used_at: DateTime.utc_now()
        })
        |> Repo.insert_or_update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp touch(computer) do
    computer |> AgentComputer.changeset(%{last_used_at: DateTime.utc_now()}) |> Repo.update()
  end

  @doc "Stops and forgets the sandbox for `agent_id`."
  def destroy(agent_id) do
    case Repo.get_by(AgentComputer, agent_id: agent_id) do
      nil ->
        {:ok, :none}

      %AgentComputer{sandbox_id: nil} = computer ->
        computer |> AgentComputer.changeset(%{status: "none"}) |> Repo.update()

      %AgentComputer{sandbox_id: sandbox_id} = computer ->
        Client.delete(sandbox_id)
        computer |> AgentComputer.changeset(%{status: "none", sandbox_id: nil}) |> Repo.update()
    end
  end

  @doc "Latest screenshot from this agent's sandboxed browser, downscaled by the gateway."
  def preview(agent_id) do
    with %AgentComputer{sandbox_id: sandbox_id} when is_binary(sandbox_id) <- Repo.get_by(AgentComputer, agent_id: agent_id),
         {:ok, %{"imageBase64" => image} = shot} <- Client.browser_screenshot(sandbox_id) do
      {:ok,
       %{
         "imageBase64" => image,
         "mime" => shot["mime"] || "image/jpeg",
         "width" => shot["width"],
         "height" => shot["height"],
         "capturedAt" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    else
      nil -> {:error, :not_available}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_available}
    end
  end

  @doc """
  Opens a viewer session, creating the sandbox if this agent has never run a browser tool.
  Opening the sheet is how a cold agent gets a computer; the touch keeps the reaper off it.
  """
  def computer_session(agent_id, body) when is_map(body) do
    case ensure_computer(agent_id) do
      {:ok, %AgentComputer{sandbox_id: sandbox_id} = computer} when is_binary(sandbox_id) ->
        touch(computer)
        Client.computer_session(sandbox_id, body)

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :not_available}
    end
  end

  def close_computer_session(agent_id, session_id),
    do: with_sandbox(agent_id, &Client.close_computer_session(&1, session_id))

  @doc "`{:ok, :no_change}` when the gateway has nothing newer than `since`."
  def computer_frame(agent_id, since \\ 0, session \\ nil),
    do: with_sandbox(agent_id, &Client.computer_frame(&1, since, session))

  def computer_state(agent_id, session \\ nil),
    do: with_sandbox(agent_id, &Client.computer_state(&1, session))

  @doc "Owner-visible views of the machine itself: what it ran, what it holds."
  def exec_log(agent_id, since, limit),
    do: with_sandbox(agent_id, &Client.exec_log(&1, since, limit))

  def tree(agent_id, path, depth), do: with_sandbox(agent_id, &Client.tree(&1, path, depth))
  def read_file(agent_id, path), do: with_sandbox(agent_id, &Client.read_file(&1, path))

  def computer_control(agent_id, body) when is_map(body),
    do: with_sandbox(agent_id, &Client.computer_control(&1, body))

  def computer_input(agent_id, body) when is_map(body),
    do: with_sandbox(agent_id, &Client.computer_input(&1, body))

  @doc "Agent-driven browsing. Unlike computer_input these do not need the user to hold control."
  def browser_navigate(agent_id, body) when is_map(body),
    do: with_ready_sandbox(agent_id, &Client.browser_navigate(&1, body))

  def browser_action(agent_id, body) when is_map(body),
    do: with_ready_sandbox(agent_id, &Client.browser_action(&1, body))

  def browser_screenshot(agent_id, max_width) when is_integer(max_width),
    do: with_ready_sandbox(agent_id, &Client.browser_screenshot(&1, max_width))

  defp with_ready_sandbox(agent_id, fun) do
    case ensure_computer(agent_id) do
      {:ok, %AgentComputer{sandbox_id: sandbox_id} = computer} when is_binary(sandbox_id) ->
        touch(computer)
        fun.(sandbox_id)

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :not_available}
    end
  end

  defp with_sandbox(agent_id, fun) do
    case sandbox_id_for(agent_id) do
      sandbox_id when is_binary(sandbox_id) -> fun.(sandbox_id)
      _ -> {:error, :not_available}
    end
  end

  def sandbox_id_for(agent_id) do
    case Repo.get_by(AgentComputer, agent_id: agent_id) do
      %AgentComputer{sandbox_id: sandbox_id} -> sandbox_id
      nil -> nil
    end
  end

  @doc "True when the agent's sandbox was touched at/after `since`. Pure DB read, no gateway call."
  def used_since?(agent_id, %DateTime{} = since) do
    case Repo.get_by(AgentComputer, agent_id: agent_id) do
      %AgentComputer{last_used_at: %DateTime{} = last_used_at} -> DateTime.compare(last_used_at, since) != :lt
      _ -> false
    end
  end
end
