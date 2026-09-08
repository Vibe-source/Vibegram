defmodule Vibe.GroupKeys do
  @moduledoc """
  Relay for group epoch keys — the distribution half of `vibe_core::group`.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Vibe.Repo
  alias Vibe.Schemas.GroupEpochKey

  # An epoch key is 32 bytes of AES-256 sealed to one recipient.
  @max_sealed_key_bytes 8 * 1024

  # How many undelivered keys one sender may have outstanding to one recipient.
  @max_pending_per_sender 128

  # Largest batch one call may post.
  @max_batch 200

  @doc """
  Store epoch keys posted by `sender_user_id`.
  """
  def post_epoch_keys(sender_user_id, params) when is_binary(sender_user_id) and is_map(params) do
    chat_id = params["chatId"] || params["chat_id"]
    entries = params["keys"] || params["entries"]

    with {:ok, chat_id} <- validate_id(chat_id),
         :ok <- authorize_sender(chat_id, sender_user_id),
         {:ok, entries} <- validate_batch(entries),
         {:ok, rows} <- build_rows(entries, chat_id, sender_user_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      rows = Enum.map(rows, &Map.merge(&1, %{inserted_at: now, updated_at: now}))

      {count, _} =
        Repo.insert_all(GroupEpochKey, rows,
          on_conflict: :nothing,
          conflict_target: [:recipient_user_id, :chat_id, :epoch]
        )

      {:ok, count}
    end
  end

  def post_epoch_keys(_sender_user_id, _params), do: {:error, :invalid_request}

  @doc """
  Every epoch key still waiting for `user_id`.
  """
  def pending_epoch_keys(user_id) when is_binary(user_id) do
    GroupEpochKey
    |> where([k], k.recipient_user_id == ^user_id and is_nil(k.delivered_at))
    |> order_by([k], asc: k.chat_id, asc: k.epoch)
    |> Repo.all()
  end

  def pending_epoch_keys(_user_id), do: []

  @doc """
  Mark one epoch key installed.
  """
  def ack_epoch_key(user_id, id) when is_binary(user_id) and is_binary(id) do
    query =
      from(k in GroupEpochKey,
        where: k.id == ^id and k.recipient_user_id == ^user_id and is_nil(k.delivered_at)
      )

    case Repo.update_all(query,
           set: [delivered_at: DateTime.utc_now() |> DateTime.truncate(:second)]
         ) do
      {1, _} -> :ok
      _ -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def ack_epoch_key(_user_id, _id), do: {:error, :not_found}


  defp authorize_sender(chat_id, sender_user_id) do
    case Vibe.Chat.get_room_type(chat_id) do
      "channel" ->
        if Vibe.Chat.get_user_role(chat_id, sender_user_id) in ["owner", "admin"] do
          :ok
        else
          Logger.warning(
            "[GroupKeys] refused epoch-key post from non-admin chat=#{chat_id} user=#{sender_user_id}"
          )

          {:error, :not_allowed}
        end

      "group" ->
        if Vibe.Chat.get_user_role(chat_id, sender_user_id) do
          :ok
        else
          Logger.warning(
            "[GroupKeys] refused epoch-key post from non-member chat=#{chat_id} user=#{sender_user_id}"
          )

          {:error, :not_allowed}
        end

      other ->
        Logger.warning("[GroupKeys] refused epoch-key post for room_type=#{inspect(other)}")
        {:error, :not_allowed}
    end
  end


  defp validate_batch(entries) when is_list(entries) do
    cond do
      entries == [] -> {:error, :invalid_request}
      length(entries) > @max_batch -> {:error, :too_many}
      true -> {:ok, entries}
    end
  end

  defp validate_batch(_entries), do: {:error, :invalid_request}

  defp build_rows(entries, chat_id, sender_user_id) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      with true <- is_map(entry),
           {:ok, recipient_id} <-
             validate_id(entry["recipientUserId"] || entry["recipient_user_id"]),
           {:ok, epoch} <- validate_epoch(entry["epoch"]),
           {:ok, sealed} <- decode_blob(entry["sealedKey"] || entry["sealed_key"]),
           :ok <- check_pending_quota(recipient_id, sender_user_id) do
        row = %{
          recipient_user_id: recipient_id,
          sender_user_id: sender_user_id,
          chat_id: chat_id,
          epoch: epoch,
          sealed_key: sealed
        }

        {:cont, {:ok, [row | acc]}}
      else
        false -> {:halt, {:error, :invalid_request}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp check_pending_quota(recipient_id, sender_id) do
    count =
      GroupEpochKey
      |> where(
        [k],
        k.recipient_user_id == ^recipient_id and k.sender_user_id == ^sender_id and
          is_nil(k.delivered_at)
      )
      |> Repo.aggregate(:count, :id)

    if count >= @max_pending_per_sender, do: {:error, :too_many_pending}, else: :ok
  end

  defp validate_epoch(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp validate_epoch(value) when is_binary(value) do
    case Integer.parse(value) do
      {epoch, ""} when epoch >= 0 -> {:ok, epoch}
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_epoch(_value), do: {:error, :invalid_request}

  defp validate_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" or String.length(trimmed) > 255 do
      {:error, :invalid_request}
    else
      {:ok, trimmed}
    end
  end

  defp validate_id(_value), do: {:error, :invalid_request}

  defp decode_blob(value) when is_binary(value) do
    case Base.decode64(String.trim(value)) do
      {:ok, binary} when byte_size(binary) > 0 and byte_size(binary) <= @max_sealed_key_bytes ->
        {:ok, binary}

      {:ok, _binary} ->
        {:error, :too_large}

      _ ->
        {:error, :invalid_encoding}
    end
  end

  defp decode_blob(_value), do: {:error, :invalid_encoding}
end
