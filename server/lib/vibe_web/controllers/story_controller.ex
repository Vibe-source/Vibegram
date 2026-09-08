defmodule VibeWeb.StoryController do
  @moduledoc """
  Controller for story endpoints.
  Handles story creation, retrieval, viewing, and visibility management.
  """
  use VibeWeb, :controller

  alias Vibe.Stories
  alias Vibe.Storage

  @doc """
  Creates a new story.
  """
  def create(conn, params) do
    user_id = conn.assigns.current_user.id

    validity_hours = params["duration"] || 24
    expires_at = DateTime.utc_now() |> DateTime.add(trunc(validity_hours * 3600), :second) |> DateTime.truncate(:second)

    attrs = %{
      user_id: user_id,
      media_url: params["media_url"],
      media_type: params["media_type"] || "image",
      caption: params["caption"],
      visibility: params["visibility"] || "everyone",
      visible_to: params["visible_to"] || [],
      hidden_from: params["hidden_from"] || [],
      original_media_url: params["original_media_url"],
      expires_at: expires_at
    }

    case Stories.create_story(attrs) do
      {:ok, story} ->
        json(conn, %{
          success: true,
          story: story_to_json(story)
        })

      {:error, changeset} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to create story", details: inspect(changeset.errors)})
    end
  end

  @doc """
  Gets the stories feed for a user.
  GET /api/stories/feed/:user_id
  """
  def feed(conn, %{"user_id" => user_id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
      feed = Stories.get_stories_feed(current_id)

      json(conn, %{
        success: true,
        feed: Enum.map(feed, fn group ->
          %{
            user_id: group.user_id,
            username: group.username,
            profile_image: group.profile_image,
            has_unseen: group.has_unseen,
            stories: Enum.map(group.stories, &story_to_json/1)
          }
        end)
      })
    end
  end

  @doc """
  Gets a user's own stories with view information.
  GET /api/stories/my/:user_id
  """
  def my_stories(conn, %{"user_id" => user_id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
      stories = Stories.get_my_stories(current_id)

      json(conn, %{
        success: true,
        stories: Enum.map(stories, &story_to_json/1)
      })
    end
  end

  @doc """
  Gets a specific user's stories (for viewing).
  GET /api/stories/user/:target_user_id?viewer_id=xxx
  """
  def user_stories(conn, %{"target_user_id" => target_user_id} = params) do
    viewer_id = conn.assigns.current_user.id
    stories = Stories.get_user_stories(target_user_id)

    visible_stories =
      if params["viewer_id"] && params["viewer_id"] != viewer_id do
        []
      else
        Enum.filter(stories, &Stories.can_view_story?(&1, viewer_id))
      end

    json(conn, %{
      success: true,
      stories: Enum.map(visible_stories, &story_to_json/1)
    })
  end

  @doc """
  Marks a story as viewed.
  """
  def view(conn, %{"story_id" => story_id} = params) do
    viewer_id = conn.assigns.current_user.id

    if params["viewer_id"] && params["viewer_id"] != viewer_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
    case Stories.mark_story_viewed(story_id, viewer_id) do
      {:ok, _} ->
        json(conn, %{success: true})

      {:error, _} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to mark story as viewed"})
    end
    end
  end

  @doc """
  Gets viewers for a story (owner only).
  GET /api/stories/:story_id/viewers?user_id=xxx
  """
  def viewers(conn, %{"story_id" => story_id}) do
    user_id = conn.assigns.current_user.id
    story = Stories.get_story(story_id)

    cond do
      is_nil(story) ->
        conn |> put_status(:not_found) |> json(%{error: "Story not found"})

      story.user_id != user_id ->
        conn |> put_status(:forbidden) |> json(%{error: "Not authorized"})

      true ->
        viewers = Stories.get_story_viewers(story_id)
        json(conn, %{success: true, viewers: viewers, count: length(viewers)})
    end
  end

  @doc """
  Deletes a story.
  DELETE /api/stories/:story_id?user_id=xxx
  """
  def delete(conn, %{"story_id" => story_id}) do
    user_id = conn.assigns.current_user.id
    case Stories.delete_story(story_id, user_id) do
      {:ok, _} ->
        json(conn, %{success: true})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Story not found"})

      {:error, :unauthorized} ->
        conn |> put_status(:forbidden) |> json(%{error: "Not authorized"})
    end
  end

  @doc """
  Updates story visibility.
  """
  def update_visibility(conn, %{"story_id" => story_id} = params) do
    user_id = conn.assigns.current_user.id
    visibility = params["visibility"]
    visible_to = params["visible_to"] || []
    hidden_from = params["hidden_from"] || []

    case Stories.update_visibility(story_id, user_id, visibility, visible_to, hidden_from) do
      {:ok, story} ->
        json(conn, %{success: true, story: story_to_json(story)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Story not found"})

      {:error, :unauthorized} ->
        conn |> put_status(:forbidden) |> json(%{error: "Not authorized"})

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{error: inspect(changeset.errors)})
    end
  end

  # Helper to convert story to JSON-safe map
  defp story_to_json(story) do
    %{
      id: story.id,
      user_id: story.user_id,
      media_url: Storage.rewrite_public_url(story.media_url),
      media_type: story.media_type,
      caption: story.caption,
      duration: story.duration,
      original_media_url: Storage.rewrite_public_url(story.original_media_url),
      visibility: story.visibility,
      view_count: Map.get(story, :view_count, 0),
      expires_at: format_datetime(story.expires_at),
      created_at: format_datetime(story.inserted_at)
    }
  end

  # Handle both DateTime and NaiveDateTime
  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
end
