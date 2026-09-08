defmodule Vibe.Subscriptions do
  @moduledoc """
  Context for managing subscription plans and user subscriptions.
  """

  import Ecto.Query, warn: false
  alias Vibe.Repo
  alias Vibe.Subscriptions.{Plan, UserSubscription}
  alias Vibe.Accounts
  alias Vibe.Badges

  # Plan Functions

  def list_plans do
    Repo.all(from p in Plan, order_by: [asc: p.price_cents])
  end

  def get_plan(id), do: Repo.get(Plan, id)

  def get_plan_by_name(name) do
    Repo.get_by(Plan, name: String.downcase(name))
  end

  def get_plan_by_variant(variant_id) do
    Repo.get_by(Plan, lemon_squeezy_variant_id: variant_id)
  end

  def create_plan(attrs) do
    %Plan{}
    |> Plan.changeset(attrs)
    |> Repo.insert()
  end


  def get_user_subscription(user_id) do
    Repo.one(
      from s in UserSubscription,
        where: s.user_id == ^user_id and s.status == "active",
        preload: [:plan]
    )
  end

  def get_subscription_by_ls_id(ls_subscription_id) do
    Repo.get_by(UserSubscription, lemon_squeezy_subscription_id: ls_subscription_id)
  end

  def create_subscription(attrs) do
    %UserSubscription{}
    |> UserSubscription.changeset(attrs)
    |> Repo.insert()
  end

  def update_subscription(%UserSubscription{} = subscription, attrs) do
    subscription
    |> UserSubscription.changeset(attrs)
    |> Repo.update()
  end

  def cancel_subscription(%UserSubscription{} = subscription) do
    update_subscription(subscription, %{
      status: "cancelled",
      cancelled_at: DateTime.utc_now()
    })
  end


  @doc """
  Calculate the effective tier for a user based on subscription and referrals.
  Priority: Gold > Silver > Bronze > Free
  """
  def calculate_user_tier(user_id) do
    case get_user_subscription(user_id) do
      %{plan: %{name: tier}} when tier in ["gold", "silver"] ->
        String.downcase(tier)

      _ ->
        user = Accounts.get_user(user_id)

        if user && user.referral_count >= 4000 do
          "bronze"
        else
          "free"
        end
    end
  end

  @doc """
  Check if user has access to AI features (Silver+ tier)
  """
  def has_ai_features?(user_id) do
    case get_user_subscription(user_id) do
      %{plan: %{ai_features_enabled: true}} -> true
      _ -> false
    end
  end

  @doc """
  Check if user has access to business auto-reply (Silver+ tier)
  """
  def has_business_auto_reply?(user_id) do
    case get_user_subscription(user_id) do
      %{plan: %{business_auto_reply: true}} -> true
      _ -> false
    end
  end

  @unlimited_agent_cap 1_000_000

  def agent_limit_for_user(user_id) do
    case Accounts.get_user(user_id) do
      %{tier: "gold"} -> @unlimited_agent_cap
      %{tier: "silver"} -> @unlimited_agent_cap
      %{tier: "bronze"} -> @unlimited_agent_cap
      _ -> @unlimited_agent_cap
    end
  end


  @doc """
  Handle new subscription creation (called from webhook)
  """
  def handle_subscription_created(user_id, plan_id, ls_subscription_id, ls_customer_id, renews_at) do
    plan = get_plan(plan_id)

    with {:ok, subscription} <-
           create_subscription(%{
             user_id: user_id,
             plan_id: plan_id,
             status: "active",
             lemon_squeezy_subscription_id: ls_subscription_id,
             lemon_squeezy_customer_id: ls_customer_id,
             current_period_start: DateTime.utc_now(),
             current_period_end: renews_at
           }),
         {:ok, _user} <- Accounts.update_user(Accounts.get_user(user_id), %{tier: plan.name}),
         {:ok, _badge} <- Badges.award_badge(user_id, plan.name, "subscription") do
      {:ok, subscription}
    end
  end

  @doc """
  Handle subscription cancellation (called from webhook)
  """
  def handle_subscription_cancelled(ls_subscription_id) do
    case get_subscription_by_ls_id(ls_subscription_id) do
      nil ->
        {:error, :not_found}

      subscription ->
        with {:ok, updated} <- cancel_subscription(subscription) do
          user = Accounts.get_user(subscription.user_id)
          new_tier = calculate_user_tier(subscription.user_id)
          Accounts.update_user(user, %{tier: new_tier})
          {:ok, updated}
        end
    end
  end

  @doc """
  Handle subscription renewal/update (called from webhook)
  """
  def handle_subscription_updated(ls_subscription_id, attrs) do
    case get_subscription_by_ls_id(ls_subscription_id) do
      nil -> {:error, :not_found}
      subscription -> update_subscription(subscription, attrs)
    end
  end
end
