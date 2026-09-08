defmodule Vibe.Referrals do
  @moduledoc """
  Context for managing referral tracking and rewards.
  """

  import Ecto.Query, warn: false
  alias Vibe.Repo
  alias Vibe.Referrals.Referral
  alias Vibe.Accounts
  alias Vibe.Badges

  @bronze_threshold 4000

  # Referral Code Management

  @doc """
  Generate a unique referral code for a user.
  """
  def generate_referral_code(user_id) do
    user = Accounts.get_user(user_id)

    if user.referral_code do
      {:ok, user.referral_code}
    else
      code = generate_unique_code()

      case Accounts.update_user(user, %{referral_code: code}) do
        {:ok, updated_user} -> {:ok, updated_user.referral_code}
        error -> error
      end
    end
  end

  defp generate_unique_code do
    code =
      :crypto.strong_rand_bytes(6)
      |> Base.url_encode64()
      |> binary_part(0, 8)
      |> String.upcase()

    if Repo.exists?(from u in Accounts.User, where: u.referral_code == ^code) do
      generate_unique_code()
    else
      code
    end
  end

  @doc """
  Get referral code for a user, generating one if it doesn't exist.
  """
  def get_or_create_referral_code(user_id) do
    user = Accounts.get_user(user_id)

    if user && user.referral_code do
      {:ok, user.referral_code}
    else
      generate_referral_code(user_id)
    end
  end

  # Referral Tracking

  @doc """
  Track a new referral when a user signs up with a referral code.
  """
  def track_referral(referral_code, referred_user_id) do
    referrer = Repo.get_by(Accounts.User, referral_code: referral_code)

    cond do
      is_nil(referrer) ->
        {:error, :invalid_code}

      referrer.id == referred_user_id ->
        {:error, :self_referral}

      true ->
        %Referral{}
        |> Referral.changeset(%{
          referrer_id: referrer.id,
          referred_id: referred_user_id,
          referral_code: referral_code,
          status: "pending"
        })
        |> Repo.insert(on_conflict: :nothing)
    end
  end

  @doc """
  Verify a referral (called after referred user performs qualifying action).
  """
  def verify_referral(referred_user_id) do
    referral = Repo.get_by(Referral, referred_id: referred_user_id, status: "pending")

    if referral do
      Repo.transaction(fn ->
        {:ok, _} =
          referral
          |> Referral.changeset(%{status: "verified", verified_at: DateTime.utc_now()})
          |> Repo.update()

        Repo.update_all(
          from(u in Accounts.User, where: u.id == ^referral.referrer_id),
          inc: [referral_count: 1]
        )

        check_and_award_bronze(referral.referrer_id)
      end)
    else
      {:ok, :no_pending_referral}
    end
  end

  defp check_and_award_bronze(user_id) do
    user = Accounts.get_user(user_id)

    if user.referral_count >= @bronze_threshold && user.tier == "free" do
      Badges.award_badge(user_id, "bronze", "referral")
      Accounts.update_user(user, %{tier: "bronze"})
    end
  end

  # Stats & Queries

  @doc """
  Get referral statistics for a user.
  """
  def get_referral_stats(user_id) do
    user = Accounts.get_user(user_id)

    pending_count =
      Repo.one(
        from r in Referral,
          where: r.referrer_id == ^user_id and r.status == "pending",
          select: count(r.id)
      )

    verified_count = user.referral_count || 0

    %{
      referral_code: user.referral_code,
      verified_count: verified_count,
      pending_count: pending_count,
      total_count: verified_count + pending_count,
      bronze_threshold: @bronze_threshold,
      progress_percent: min(100, round(verified_count / @bronze_threshold * 100))
    }
  end

  @doc """
  Get list of referrals made by a user.
  """
  def list_referrals(user_id) do
    Repo.all(
      from r in Referral,
        where: r.referrer_id == ^user_id,
        order_by: [desc: r.inserted_at],
        preload: [:referred]
    )
  end
end
