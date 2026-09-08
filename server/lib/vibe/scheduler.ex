defmodule Vibe.Scheduler do
  @moduledoc """
  GenServer that manages scheduled channel posts.
  """

  use GenServer
  require Logger

  alias Vibe.Chat
  alias Vibe.Notifications

  # ── Client API ──────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Schedule a new post. Inserts to DB and sets a timer."
  def schedule_post(attrs) do
    GenServer.call(__MODULE__, {:schedule, attrs})
  end

  @doc "Cancel a pending scheduled post."
  def cancel_post(post_id, user_id) do
    GenServer.call(__MODULE__, {:cancel, post_id, user_id})
  end

  # ── Server Callbacks ────────────────────────────────────────────

  @impl true
  def init(_state) do
    Process.send_after(self(), :load_pending, 2_000)
    {:ok, %{timers: %{}, load_retry_count: 0}}
  end

  @impl true
  def handle_info(:load_pending, state) do
    case load_and_schedule_pending(state.timers) do
      {:ok, timers, count} ->
        Logger.info("[Scheduler] Loaded #{count} pending scheduled posts")
        {:noreply, %{state | timers: timers, load_retry_count: 0}}

      {:error, reason} ->
        retry_count = state.load_retry_count + 1
        retry_ms = load_retry_backoff_ms(retry_count)

        Logger.error(
          "[Scheduler] Failed to load pending posts (attempt #{retry_count}). Retrying in #{retry_ms}ms. Reason: #{inspect(reason)}"
        )

        Process.send_after(self(), :load_pending, retry_ms)
        {:noreply, %{state | load_retry_count: retry_count}}
    end
  end

  @impl true
  def handle_info({:execute_post, post_id}, state) do
    execute_post(post_id)
    timers = Map.delete(state.timers, post_id)
    {:noreply, %{state | timers: timers}}
  end

  @impl true
  def handle_call({:schedule, attrs}, _from, state) do
    case Chat.create_scheduled_post(attrs) do
      {:ok, post} ->
        timers = schedule_timer(state.timers, post)
        {:reply, {:ok, post}, %{state | timers: timers}}

      {:error, changeset} ->
        {:reply, {:error, changeset}, state}
    end
  end

  @impl true
  def handle_call({:cancel, post_id, user_id}, _from, state) do
    case Chat.cancel_scheduled_post(post_id, user_id) do
      {:ok, _post} ->
        case Map.get(state.timers, post_id) do
          nil -> :ok
          ref -> Process.cancel_timer(ref)
        end

        timers = Map.delete(state.timers, post_id)
        {:reply, :ok, %{state | timers: timers}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # ── Private ─────────────────────────────────────────────────────

  defp load_and_schedule_pending(timers) do
    import Ecto.Query
    alias Vibe.Chat.ScheduledPost

    try do
      posts =
        Vibe.Repo.all(
          from(sp in ScheduledPost,
            where: sp.status == "pending"
          )
        )

      timers =
        Enum.reduce(posts, timers, fn post, acc ->
          schedule_timer(acc, post)
        end)

      {:ok, timers, length(posts)}
    rescue
      e in DBConnection.ConnectionError -> {:error, e}
      e in Postgrex.Error -> {:error, e}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp schedule_timer(timers, post) do
    if Map.has_key?(timers, post.id) do
      timers
    else
      now = DateTime.utc_now()
      scheduled = post.scheduled_at

      delay_ms = DateTime.diff(scheduled, now, :millisecond)
      delay_ms = max(delay_ms, 0)

      ref = Process.send_after(self(), {:execute_post, post.id}, delay_ms)
      Map.put(timers, post.id, ref)
    end
  end

  defp load_retry_backoff_ms(attempt) do
    base = 2_000
    max = 60_000
    jitter = :rand.uniform(250)
    min(round(base * :math.pow(2, attempt - 1)) + jitter, max)
  end

  defp execute_post(post_id) do
    case Chat.claim_scheduled_post(post_id) do
      {:ok, post} ->
        message_id = Ecto.UUID.generate()
        timestamp = :os.system_time(:millisecond)

        message_attrs = %{
          id: message_id,
          chat_id: post.channel_id,
          from_id: post.user_id,
          encrypted_content: post.content,
          type: post.type || "text",
          media_url: post.media_url,
          timestamp: timestamp
        }

        case Chat.add_message(message_attrs) do
          {:ok, _msg} ->
            broadcast_payload = %{
              "id" => message_id,
              "fromId" => post.user_id,
              "chatId" => post.channel_id,
              "encryptedContent" => post.content,
              "type" => post.type || "text",
              "mediaUrl" => post.media_url,
              "timestamp" => timestamp
            }

            VibeWeb.Endpoint.broadcast!("chat:#{post.channel_id}", "message", broadcast_payload)

            mirrored_message = Chat.mirrored_message_payload(broadcast_payload)

            Chat.get_participant_ids(post.channel_id)
            |> Enum.each(fn participant_id ->
              if participant_id != post.user_id do
                VibeWeb.Endpoint.broadcast!("user:#{participant_id}", "new_message", %{
                  chat_id: post.channel_id,
                  from_id: post.user_id,
                  message_id: message_id,
                  timestamp: timestamp,
                  message: mirrored_message
                })

                _ =
                  Notifications.send_message_push(participant_id, %{
                    "chat_id" => post.channel_id,
                    "from_id" => post.user_id,
                    "message_id" => message_id
                  })
              end
            end)

            Logger.info(
              "[Scheduler] Posted scheduled message #{post_id} to channel #{post.channel_id}"
            )

          {:error, reason} ->
            Logger.error(
              "[Scheduler] Failed to post scheduled message #{post_id}: #{inspect(reason)}"
            )

            Chat.reopen_scheduled_post(post_id)
        end

      :already_claimed ->
        Logger.warning("[Scheduler] Post #{post_id} already claimed elsewhere, skipping")
    end
  end
end
