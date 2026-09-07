defmodule Vibe.AI.TeamComputer.Auth do
  @moduledoc """
  Per-run credentials for the team-computer MCP endpoint (docs/agent-computer-v1.md §3.3).

  The `claude` CLI a role worker runs is handed a signed, short-lived token instead of a
  shared secret, and the endpoint reads identity back out of that token. Nothing the CLI
  sends — headers, query, body — is trusted to say which worker or chat it is.
  """

  alias Vibe.AI.LocalAgentWorker

  @salt "team-computer-run"
  @max_age_seconds 900

  @doc "Seconds a minted token stays valid."
  def max_age_seconds, do: @max_age_seconds

  @doc """
  Mints the bearer token for one worker run. `{:ok, token}` only for a real role worker
  and a well-formed chat id; the caller sets it as `VIBE_TEAM_COMPUTER_TOKEN`.
  """
  def mint_run_token(agent_user_id, chat_id, run_id \\ nil)

  def mint_run_token(agent_user_id, chat_id, run_id)
      when is_binary(agent_user_id) and is_binary(chat_id) do
    with true <- role_worker?(agent_user_id),
         true <- uuid?(chat_id) do
      claims = %{
        "agentUserId" => agent_user_id,
        "chatId" => chat_id,
        "runId" => normalize_run_id(run_id)
      }

      {:ok, Phoenix.Token.sign(VibeWeb.Endpoint, @salt, claims)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def mint_run_token(_agent_user_id, _chat_id, _run_id), do: {:error, :unauthorized}

  @doc """
  Verifies a bearer and returns `{:ok, %{agent_user_id, chat_id, run_id, worker}}`.
  Fail-closed: an expired, forged or non-roster token is `{:error, :unauthorized}`.
  """
  def verify_run_token(token) when is_binary(token) and token != "" do
    case Phoenix.Token.verify(VibeWeb.Endpoint, @salt, token, max_age: @max_age_seconds) do
      {:ok, %{"agentUserId" => agent_user_id, "chatId" => chat_id, "runId" => run_id}} ->
        build_identity(agent_user_id, chat_id, run_id)

      _ ->
        {:error, :unauthorized}
    end
  end

  def verify_run_token(_token), do: {:error, :unauthorized}

  @doc "The roster entry for a role worker's agent user id, or nil."
  def worker_for(agent_user_id) when is_binary(agent_user_id) do
    LocalAgentWorker.workers()
    |> Map.values()
    |> Enum.find(fn worker ->
      worker[:runtime] == :server and worker[:agent_user_id] == agent_user_id
    end)
  end

  def worker_for(_agent_user_id), do: nil

  @doc "True when the id belongs to a server-runtime role worker on the frozen roster."
  def role_worker?(agent_user_id), do: not is_nil(worker_for(agent_user_id))

  defp build_identity(agent_user_id, chat_id, run_id)
       when is_binary(agent_user_id) and is_binary(chat_id) do
    case worker_for(agent_user_id) do
      nil ->
        {:error, :unauthorized}

      worker ->
        if uuid?(chat_id) do
          {:ok,
           %{
             agent_user_id: agent_user_id,
             chat_id: chat_id,
             run_id: normalize_run_id(run_id),
             worker: worker
           }}
        else
          {:error, :unauthorized}
        end
    end
  end

  defp build_identity(_agent_user_id, _chat_id, _run_id), do: {:error, :unauthorized}

  defp normalize_run_id(run_id) when is_binary(run_id) and run_id != "", do: run_id
  defp normalize_run_id(_run_id), do: Ecto.UUID.generate()

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false
end
