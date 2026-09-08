defmodule Vibe.StoriesBlockTest do
  use ExUnit.Case, async: false

  alias Vibe.Accounts
  alias Vibe.Accounts.User
  alias Vibe.Repo
  alias Vibe.Stories

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    viewer = insert_user("story_viewer")
    author = insert_user("story_author")
    {:ok, story} = Stories.create_story(%{user_id: author.id, media_url: "https://example.test/story.jpg", media_type: "image"})
    %{viewer: viewer, author: author, story: story}
  end

  test "an author-blocked viewer cannot view or list the story", ctx do
    {:ok, _} = Accounts.block_user(ctx.author.id, ctx.viewer.id)
    refute Stories.can_view_story?(ctx.story, ctx.viewer.id)
    refute feed_has_author?(ctx.viewer.id, ctx.author.id)
  end

  test "a viewer-blocked author cannot be viewed or listed", ctx do
    {:ok, _} = Accounts.block_user(ctx.viewer.id, ctx.author.id)
    refute Stories.can_view_story?(ctx.story, ctx.viewer.id)
    refute feed_has_author?(ctx.viewer.id, ctx.author.id)
  end

  test "an unblocked author remains visible", ctx do
    assert Stories.can_view_story?(ctx.story, ctx.viewer.id)
    assert feed_has_author?(ctx.viewer.id, ctx.author.id)
  end

  defp feed_has_author?(viewer_id, author_id) do
    Enum.any?(Stories.get_stories_feed(viewer_id), &(&1.user_id == author_id))
  end

  defp insert_user(prefix) do
    suffix = System.unique_integer([:positive])

    Repo.insert!(%User{
      id: Ecto.UUID.generate(),
      username: "#{prefix}_#{suffix}",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}",
      is_agent: false
    })
  end
end
