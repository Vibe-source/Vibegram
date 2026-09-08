defmodule Vibe.AgentDeliveryScheduler do
  @moduledoc false

  use GenServer
  require Logger

  alias Vibe.Agents
  alias Vibe.Net.SafeURL

  @poll_interval_ms 15_000
  @max_attempts 3

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Process.send_after(self(), :poll, 5_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    Agents.due_delivery_events()
    |> Enum.each(&deliver_event/1)

    _ = Vibe.AI.AgentDecisions.expire_due_tasks()

    Process.send_after(self(), :poll, @poll_interval_ms)
    {:noreply, state}
  end

  defp deliver_event(event) do
    body = Jason.encode!(event.request_body || %{})
    timestamp = Integer.to_string(System.system_time(:second))
    
    with {:ok, _uri} <- SafeURL.validate(event.target_url),
         {:ok, secret} <- Agents.callback_signing_secret(event.agent) do
      signature =
        :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
        |> Base.encode16(case: :lower)

      headers = [
        {"content-type", "application/json"},
        {"x-vibe-agent-signature-timestamp", timestamp},
        {"x-vibe-agent-signature", signature}
      ]

      request = Finch.build(:post, event.target_url, headers, body)

      case Finch.request(request, Vibe.Finch, receive_timeout: 30_000) do
        {:ok, %{status: status}} when status in 200..299 ->
          _ =
            Agents.update_delivery_event(event, %{
              status: "completed",
              response_code: status,
              attempt_count: event.attempt_count + 1,
              last_error: nil
            })

        {:ok, %{status: status, body: response_body}} ->
          handle_failure(event, status, inspect(response_body))

        {:error, reason} ->
          handle_failure(event, nil, inspect(reason))
      end
    else
      {:error, reason}
      when reason in [:invalid_scheme, :missing_host, :invalid_url, :host_not_found, :blocked_address] ->
        handle_failure(event, nil, "Unsafe callback URL: #{inspect(reason)}")

      {:error, :missing_encrypted_secret} ->
        handle_failure(event, nil, "Missing callback signing secret. Rotate the agent secret to re-enable signed callbacks.")

      {:error, reason} ->
        handle_failure(event, nil, "Failed to load callback signing secret: #{inspect(reason)}")
    end
  end

  defp handle_failure(event, response_code, reason) do
    next_attempt_count = event.attempt_count + 1

    status =
      if next_attempt_count >= @max_attempts do
        "failed"
      else
        "retrying"
      end

    _ =
      Agents.update_delivery_event(event, %{
        status: status,
        response_code: response_code,
        attempt_count: next_attempt_count,
        last_error: reason
      })

    Logger.warning(
      "[AgentDeliveryScheduler] delivery failed id=#{event.id} status=#{inspect(response_code)} reason=#{reason}"
    )
  end
end
