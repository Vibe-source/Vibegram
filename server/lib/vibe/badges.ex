defmodule Vibe.Badges do
  @moduledoc """
  Context for managing user badges.
  """

  import Ecto.Query, warn: false
  alias Vibe.Repo
  alias Vibe.Badges.Badge

  @badge_priority %{"admin" => 5, "verified" => 4, "gold" => 3, "silver" => 2, "bronze" => 1}

  # Badge Functions

  @doc """
  Award a badge to a user.
  """
  def award_badge(user_id, badge_type, source) do
    deactivate_lower_badges(user_id, badge_type)

    %Badge{}
    |> Badge.changeset(%{
      user_id: user_id,
      badge_type: badge_type,
      earned_at: DateTime.utc_now(),
      source: source,
      active: true
    })
    |> Repo.insert(
      on_conflict: {:replace, [:active, :updated_at]},
      conflict_target: [:user_id, :badge_type]
    )
  end

  defp deactivate_lower_badges(user_id, new_badge_type) do
    new_priority = Map.get(@badge_priority, new_badge_type, 0)

    lower_types =
      @badge_priority
      |> Enum.filter(fn {_type, priority} -> priority < new_priority end)
      |> Enum.map(fn {type, _priority} -> type end)

    if length(lower_types) > 0 do
      Repo.update_all(
        from(b in Badge,
          where: b.user_id == ^user_id and b.badge_type in ^lower_types
        ),
        set: [active: false]
      )
    end
  end

  @doc """
  Get the active (highest) badge for a user.
  """
  def get_active_badge(user_id) do
    Repo.one(
      from b in Badge,
        where: b.user_id == ^user_id and b.active == true,
        order_by: [desc: b.inserted_at],
        limit: 1
    )
  end

  @doc """
  Get all badges for a user.
  """
  def list_badges(user_id) do
    Repo.all(
      from b in Badge,
        where: b.user_id == ^user_id,
        order_by: [desc: b.earned_at]
    )
  end

  @doc """
  Check if user has a specific badge.
  """
  def has_badge?(user_id, badge_type) do
    Repo.exists?(
      from b in Badge,
        where: b.user_id == ^user_id and b.badge_type == ^badge_type
    )
  end

  @doc """
  Revoke a badge from a user (e.g., when subscription cancelled).
  """
  def revoke_badge(user_id, badge_type) do
    case Repo.get_by(Badge, user_id: user_id, badge_type: badge_type) do
      nil ->
        {:error, :not_found}

      badge ->
        Repo.delete(badge)
        reactivate_highest_badge(user_id)
    end
  end

  defp reactivate_highest_badge(user_id) do
    highest =
      Repo.one(
        from b in Badge,
          where: b.user_id == ^user_id,
          order_by: [desc: fragment("CASE badge_type WHEN 'admin' THEN 5 WHEN 'verified' THEN 4 WHEN 'gold' THEN 3 WHEN 'silver' THEN 2 WHEN 'bronze' THEN 1 ELSE 0 END")],
          limit: 1
      )

    if highest do
      highest
      |> Badge.changeset(%{active: true})
      |> Repo.update()
    end
  end
end
