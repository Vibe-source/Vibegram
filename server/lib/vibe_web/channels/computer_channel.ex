defmodule VibeWeb.ComputerChannel do
  @moduledoc """
  Owner-only live view of an agent's browser (docs/agent-computer-v1.md §3.2).
  One poller per channel process, so it dies with the socket — never a global.
  """

  use Phoenix.Channel
  require Logger

  alias Vibe.AgentGateway
  alias Vibe.Agents

  @default_fps 3
  @min_fps 1
  @max_fps 10
  @input_limit 20
  @input_window_ms 1_000
  @max_consecutive_errors 3

  @impl true
  def join("computer:" <> agent_id, params, socket) do
    user_id = socket.assigns[:user_id]
    session_id = params["sessionId"] || params["session_id"]

    if is_binary(user_id) and is_binary(session_id) and session_id != "" and
         Agents.get_agent(agent_id, user_id) do
      fps = clamp_fps(params["fps"])

      socket =
        socket
        |> assign(:agent_id, agent_id)
        |> assign(:session_id, session_id)
        |> assign(:fps, fps)
        |> assign(:seq, 0)
        |> assign(:errors, 0)
        |> assign(:input_times, [])
        |> assign(:last_state, %{})

      schedule_poll(socket)
      {:ok, %{"topic" => "computer:#{agent_id}", "fps" => fps, "sessionId" => session_id}, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_info(:poll, socket) do
    case AgentGateway.computer_frame(socket.assigns.agent_id,
           since: socket.assigns.seq,
           session: socket.assigns.session_id
         ) do
      {:ok, :no_change} ->
        {:noreply, socket |> assign(:errors, 0) |> schedule_poll()}

      {:ok, frame} when is_map(frame) ->
        {:noreply, socket |> assign(:errors, 0) |> push_frame(frame) |> schedule_poll()}

      {:error, reason} ->
        poll_error(socket, reason)
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_in("input", params, socket) do
    case take_input_slot(socket) do
      {:ok, socket} ->
        body =
          params
          |> Map.take(["kind", "x", "y", "text", "key", "deltaY", "url"])
          |> Map.put("sessionId", socket.assigns.session_id)

        case AgentGateway.computer_input(socket.assigns.agent_id, body) do
          {:ok, result} when is_map(result) -> {:noreply, merge_state(socket, result)}
          _ -> {:noreply, socket}
        end

      {:dropped, socket} ->
        {:noreply, socket}
    end
  end

  def handle_in("control", params, socket) do
    case control_action(params["action"]) do
      nil ->
        {:noreply, socket}

      action ->
        body = %{
          "action" => action,
          "sessionId" => socket.assigns.session_id,
          "ttlSeconds" => params["ttlSeconds"] || params["ttl_seconds"]
        }

        case AgentGateway.computer_control(socket.assigns.agent_id, body) do
          {:ok, result} when is_map(result) ->
            socket = merge_state(socket, result)
            push(socket, "state", state_payload(socket))
            {:noreply, socket}

          _ ->
            {:noreply, socket}
        end
    end
  end

  def handle_in(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    agent_id = socket.assigns[:agent_id]
    session_id = socket.assigns[:session_id]

    if is_binary(agent_id) and is_binary(session_id) do
      AgentGateway.close_computer_session(agent_id, session_id)
    end

    :ok
  end

  defp schedule_poll(socket) do
    Process.send_after(self(), :poll, div(1_000, socket.assigns.fps))
    socket
  end

  defp push_frame(socket, frame) do
    seq = frame["seq"] || socket.assigns.seq
    socket = socket |> assign(:seq, seq) |> merge_state(frame)

    if is_binary(frame["imageBase64"]) do
      push(socket, "frame", %{
        "seq" => seq,
        "imageBase64" => frame["imageBase64"],
        "mime" => frame["mime"] || "image/jpeg",
        "width" => frame["width"],
        "height" => frame["height"],
        "url" => frame["url"],
        "title" => frame["title"],
        "loading" => frame["loading"],
        "control" => frame["control"],
        "ts" => frame["capturedAt"] || System.system_time(:millisecond)
      })
    end

    socket
  end

  defp poll_error(socket, {:http_error, status, body}) when status in [404, 410] do
    end_session(socket, body_reason(body) || "stopped")
  end

  defp poll_error(socket, _reason) do
    errors = socket.assigns.errors + 1

    if errors >= @max_consecutive_errors do
      end_session(socket, "error")
    else
      {:noreply, socket |> assign(:errors, errors) |> schedule_poll()}
    end
  end

  defp end_session(socket, reason) do
    push(socket, "session_ended", %{"reason" => reason})
    {:stop, :normal, socket}
  end

  defp body_reason(%{"reason" => reason}) when reason in ["idle", "cap", "stopped", "error"], do: reason
  defp body_reason(_), do: nil

  defp take_input_slot(socket) do
    now = System.monotonic_time(:millisecond)
    recent = Enum.filter(socket.assigns.input_times, &(now - &1 < @input_window_ms))

    if length(recent) >= @input_limit do
      {:dropped, assign(socket, :input_times, recent)}
    else
      {:ok, assign(socket, :input_times, [now | recent])}
    end
  end

  defp control_action("take"), do: "grant"
  defp control_action("grant"), do: "grant"
  defp control_action("release"), do: "release"
  defp control_action(_), do: nil

  defp merge_state(socket, map) do
    fields = Map.take(map, ["url", "title", "loading", "control", "holder", "expiresAt"])
    assign(socket, :last_state, Map.merge(socket.assigns.last_state, fields))
  end

  defp state_payload(socket) do
    state = socket.assigns.last_state

    %{
      "url" => state["url"],
      "title" => state["title"],
      "loading" => state["loading"],
      "control" => state["control"],
      "holder" => state["holder"],
      "expiresAt" => state["expiresAt"]
    }
  end

  defp clamp_fps(fps) when is_integer(fps) and fps >= @min_fps and fps <= @max_fps, do: fps
  defp clamp_fps(_), do: @default_fps
end
