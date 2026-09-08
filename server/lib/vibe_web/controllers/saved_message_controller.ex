defmodule VibeWeb.SavedMessageController do
  use VibeWeb, :controller
  alias Vibe.Chat

  def index(conn, %{"user_id" => user_id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
      messages = Chat.list_saved_messages(current_id)
      json(conn, %{data: messages})
    end
  end

  def create(conn, params) do
    attrs = Map.put(params, "user_id", conn.assigns.current_user.id)

    case Chat.save_message(attrs) do
      {:ok, message} ->
        json(conn, %{data: message})

      {:error, :content_saving_restricted} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Content protection is enabled for this channel"})

      {:error, _changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Failed to save"})
    end
  end

  # Private reaction on a saved item.
  def reaction(conn, %{"original_message_id" => id} = params) do
    emoji = params["emoji"] || params["reaction_emoji"]

    case Chat.toggle_saved_message_reaction(conn.assigns.current_user.id, id, emoji) do
      {:ok, result} ->
        json(conn, %{
          data: %{
            original_message_id: result.original_message_id,
            action: result.action,
            reactions: result.reactions
          }
        })

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Saved message not found"})

      {:error, reason} when reason in [:invalid_emoji, :invalid_id] ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid reaction"})

      {:error, _reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Failed to react"})
    end
  end

  def delete(conn, %{"user_id" => user_id, "original_message_id" => id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
      Chat.unsave_message(current_id, id)
      json(conn, %{success: true})
    end
  end
end
