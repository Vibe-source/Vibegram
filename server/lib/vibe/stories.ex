defmodule Vibe.Stories do
  @moduledoc """
  Stories context - handles story creation, retrieval, and visibility.
  Stories are 24-hour ephemeral content with privacy controls.
  """

  import Ecto.Query
  alias Vibe.Repo
  alias Vibe.Stories.{Story, StoryView}
  alias Vibe.Accounts
  alias Vibe.Accounts.{User, UserBlock}

  @doc """
  Creates a new story for a user.
  """
  def create_story(attrs) do
    %Story{}
    |> Story.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a story by ID.
  """
  def get_story(id) do
    Repo.get(Story, id)
  end

  @doc """
  Gets all active (non-expired) stories for a user.
  """
  def get_user_stories(user_id) do
    now = DateTime.utc_now()

    from(s in Story,
      where: s.user_id == ^user_id,
      where: s.expires_at > ^now,
      order_by: [asc: s.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Gets stories feed for a user - stories from contacts/friends they can see.
  Returns grouped by user with their stories.
  """
  def get_stories_feed(viewer_id) do
    now = DateTime.utc_now()

    blocked_authors =
      from(ub in UserBlock,
        where: ub.user_id == ^viewer_id,
        select: ub.blocked_user_id
      )

    blocking_authors =
      from(ub in UserBlock,
        where: ub.blocked_user_id == ^viewer_id,
        select: ub.user_id
      )

    stories = from(s in Story,
      where: s.expires_at > ^now,
      where: s.user_id != ^viewer_id,
      where: s.user_id not in subquery(blocked_authors),
      where: s.user_id not in subquery(blocking_authors),
      order_by: [desc: s.inserted_at],
      preload: [:user]
    )
    |> Repo.all()
    |> Enum.filter(fn story -> can_view_story?(story, viewer_id) end)

    all_story_ids = Enum.map(stories, & &1.id)
    viewed_story_ids =
      from(sv in StoryView,
        where: sv.story_id in ^all_story_ids,
        where: sv.viewer_id == ^viewer_id,
        select: sv.story_id
      )
      |> Repo.all()
      |> MapSet.new()

    stories
    |> Enum.group_by(& &1.user_id)
    |> Enum.map(fn {user_id, user_stories} ->
      user = List.first(user_stories).user
      has_unseen = Enum.any?(user_stories, fn s -> not MapSet.member?(viewed_story_ids, s.id) end)
      %{
        user_id: user_id,
        username: user && user.username,
        profile_image: user && user.profile_image,
        stories: user_stories,
        has_unseen: has_unseen,
        latest_at: List.first(user_stories).inserted_at
      }
    end)
    |> Enum.sort_by(& &1.latest_at, {:desc, NaiveDateTime})
  end

  @doc """
  Gets the viewer's own stories with view counts.
  """
  def get_my_stories(user_id) do
    now = DateTime.utc_now()

    stories = from(s in Story,
      where: s.user_id == ^user_id,
      where: s.expires_at > ^now,
      order_by: [desc: s.inserted_at]
    )
    |> Repo.all()

    story_ids = Enum.map(stories, & &1.id)
    view_counts =
      from(sv in StoryView,
        where: sv.story_id in ^story_ids,
        group_by: sv.story_id,
        select: {sv.story_id, count(sv.id)}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(stories, fn story ->
      Map.put(story, :view_count, Map.get(view_counts, story.id, 0))
    end)
  end

  @doc """
  Checks if a viewer can see a specific story based on visibility settings.
  """
  def can_view_story?(story, viewer_id) do
    cond do
      Accounts.blocked?(story.user_id, viewer_id) or Accounts.blocked?(viewer_id, story.user_id) ->
        false

      viewer_id in (story.hidden_from || []) ->
        false

      story.visibility == "everyone" ->
        true

      story.visibility == "custom" ->
        viewer_id in (story.visible_to || [])

      story.visibility == "contacts" ->
        true

      story.visibility == "close_friends" ->
        viewer_id in (story.visible_to || [])

      true ->
        false
    end
  end

  @doc """
  Records that a user has viewed a story.
  """
  def mark_story_viewed(story_id, viewer_id) do
    existing = Repo.get_by(StoryView, story_id: story_id, viewer_id: viewer_id)

    if existing do
      {:ok, existing}
    else
      %StoryView{}
      |> StoryView.changeset(%{story_id: story_id, viewer_id: viewer_id})
      |> Repo.insert()
      |> case do
        {:ok, view} ->
          from(s in Story, where: s.id == ^story_id)
          |> Repo.update_all(inc: [view_count: 1])
          {:ok, view}

        error ->
          error
      end
    end
  end

  @doc """
  Gets all viewers for a story.
  """
  def get_story_viewers(story_id) do
    from(sv in StoryView,
      where: sv.story_id == ^story_id,
      join: u in User, on: sv.viewer_id == u.id,
      select: %{
        user_id: u.id,
        username: u.username,
        profile_image: u.profile_image,
        viewed_at: sv.inserted_at
      },
      order_by: [desc: sv.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Gets view count for a story.
  """
  def get_story_view_count(story_id) do
    from(sv in StoryView, where: sv.story_id == ^story_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Checks if user has any unseen stories from a list.
  """
  def has_unseen_stories?(stories, viewer_id) do
    story_ids = Enum.map(stories, & &1.id)

    viewed_count = from(sv in StoryView,
      where: sv.story_id in ^story_ids,
      where: sv.viewer_id == ^viewer_id
    )
    |> Repo.aggregate(:count)

    viewed_count < length(stories)
  end

  @doc """
  Deletes a story (only owner can delete).
  """
  def delete_story(story_id, user_id) do
    story = Repo.get(Story, story_id)

    cond do
      is_nil(story) ->
        {:error, :not_found}

      story.user_id != user_id ->
        {:error, :unauthorized}

      true ->
        Repo.delete(story)
    end
  end

  @doc """
  Updates story visibility.
  """
  def update_visibility(story_id, user_id, visibility, visible_to \\ [], hidden_from \\ []) do
    story = Repo.get(Story, story_id)

    cond do
      is_nil(story) ->
        {:error, :not_found}

      story.user_id != user_id ->
        {:error, :unauthorized}

      true ->
        story
        |> Story.changeset(%{
          visibility: visibility,
          visible_to: visible_to,
          hidden_from: hidden_from
        })
        |> Repo.update()
    end
  end

  @doc """
  Cleanup expired stories - should be run periodically.
  """
  def cleanup_expired_stories do
    now = DateTime.utc_now()

    expired_story_ids = from(s in Story, where: s.expires_at < ^now, select: s.id)
    |> Repo.all()

    from(sv in StoryView, where: sv.story_id in ^expired_story_ids)
    |> Repo.delete_all()

    from(s in Story, where: s.expires_at < ^now)
    |> Repo.delete_all()
  end
end
