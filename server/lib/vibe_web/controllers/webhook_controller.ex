defmodule VibeWeb.WebhookController do
  use VibeWeb, :controller
  require Logger

  alias Vibe.Subscriptions
  alias Vibe.Accounts
  alias Vibe.Badges

  @doc """
  Handle Lemon Squeezy webhook events.
  """
  def lemon_squeezy(conn, params) do
    signature = get_req_header(conn, "x-signature") |> List.first()
    raw_body = conn.assigns[:raw_body]

    if verify_signature(raw_body, signature) do
      handle_event(params)
      json(conn, %{received: true})
    else
      Logger.warning("Invalid Lemon Squeezy webhook signature")
      conn |> put_status(401) |> json(%{error: "Invalid signature"})
    end
  end

  defp verify_signature(body, signature) do
    webhook_secret = Application.get_env(:vibe, :lemon_squeezy)[:webhook_secret]

    if is_nil(webhook_secret) do
      Logger.warning("Lemon Squeezy webhook secret not configured")
      false
    else
      expected =
        :crypto.mac(:hmac, :sha256, webhook_secret, body || "")
        |> Base.encode16(case: :lower)

      Plug.Crypto.secure_compare(expected, signature || "")
    end
  end

  defp handle_event(%{"meta" => %{"event_name" => event_name}, "data" => data}) do
    Logger.info("Processing Lemon Squeezy event: #{event_name}")

    case event_name do
      "subscription_created" -> handle_subscription_created(data)
      "subscription_updated" -> handle_subscription_updated(data)
      "subscription_cancelled" -> handle_subscription_cancelled(data)
      "subscription_resumed" -> handle_subscription_resumed(data)
      "subscription_expired" -> handle_subscription_expired(data)
      "subscription_payment_success" -> handle_payment_success(data)
      "subscription_payment_failed" -> handle_payment_failed(data)
      _ -> Logger.info("Unhandled Lemon Squeezy event: #{event_name}")
    end
  end

  defp handle_event(params) do
    Logger.warning("Invalid webhook payload: #{inspect(params)}")
  end

  # Event Handlers

  defp handle_subscription_created(data) do
    attrs = data["attributes"]
    custom_data = attrs["custom_data"] || %{}
    user_id = custom_data["user_id"]

    if is_nil(user_id) do
      Logger.error("Subscription created without user_id in custom_data")
    else
      variant_id = to_string(attrs["variant_id"])
      plan = Subscriptions.get_plan_by_variant(variant_id)

      if plan do
        renews_at = parse_datetime(attrs["renews_at"])

        case Subscriptions.handle_subscription_created(
               user_id,
               plan.id,
               to_string(data["id"]),
               to_string(attrs["customer_id"]),
               renews_at
             ) do
          {:ok, _subscription} ->
            Logger.info("Subscription created for user #{user_id}, plan: #{plan.name}")

          {:error, reason} ->
            Logger.error("Failed to create subscription: #{inspect(reason)}")
        end
      else
        Logger.error("Plan not found for variant_id: #{variant_id}")
      end
    end
  end

  defp handle_subscription_updated(data) do
    attrs = data["attributes"]
    ls_subscription_id = to_string(data["id"])

    update_attrs = %{
      status: map_status(attrs["status"]),
      current_period_end: parse_datetime(attrs["renews_at"])
    }

    case Subscriptions.handle_subscription_updated(ls_subscription_id, update_attrs) do
      {:ok, _} -> Logger.info("Subscription #{ls_subscription_id} updated")
      {:error, reason} -> Logger.error("Failed to update subscription: #{inspect(reason)}")
    end
  end

  defp handle_subscription_cancelled(data) do
    ls_subscription_id = to_string(data["id"])

    case Subscriptions.handle_subscription_cancelled(ls_subscription_id) do
      {:ok, _} ->
        Logger.info("Subscription #{ls_subscription_id} cancelled")

      {:error, reason} ->
        Logger.error("Failed to cancel subscription: #{inspect(reason)}")
    end
  end

  defp handle_subscription_resumed(data) do
    attrs = data["attributes"]
    ls_subscription_id = to_string(data["id"])

    subscription = Subscriptions.get_subscription_by_ls_id(ls_subscription_id)

    if subscription do
      Subscriptions.update_subscription(subscription, %{
        status: "active",
        cancelled_at: nil,
        current_period_end: parse_datetime(attrs["renews_at"])
      })

      user = Accounts.get_user(subscription.user_id)
      plan = Subscriptions.get_plan(subscription.plan_id)

      if user && plan do
        Accounts.update_user(user, %{tier: plan.name})
        Badges.award_badge(user.id, plan.name, "subscription")
      end

      Logger.info("Subscription #{ls_subscription_id} resumed")
    end
  end

  defp handle_subscription_expired(data) do
    ls_subscription_id = to_string(data["id"])
    subscription = Subscriptions.get_subscription_by_ls_id(ls_subscription_id)

    if subscription do
      Subscriptions.update_subscription(subscription, %{status: "expired"})

      user = Accounts.get_user(subscription.user_id)

      if user do
        new_tier = Subscriptions.calculate_user_tier(subscription.user_id)
        Accounts.update_user(user, %{tier: new_tier})
      end

      Logger.info("Subscription #{ls_subscription_id} expired")
    end
  end

  defp handle_payment_success(data) do
    ls_subscription_id = to_string(data["attributes"]["subscription_id"])
    Logger.info("Payment successful for subscription #{ls_subscription_id}")
  end

  defp handle_payment_failed(data) do
    ls_subscription_id = to_string(data["attributes"]["subscription_id"])
    subscription = Subscriptions.get_subscription_by_ls_id(ls_subscription_id)

    if subscription do
      Subscriptions.update_subscription(subscription, %{status: "past_due"})
    end

    Logger.warning("Payment failed for subscription #{ls_subscription_id}")
  end

  # Helpers

  defp parse_datetime(nil), do: nil

  defp parse_datetime(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp map_status("active"), do: "active"
  defp map_status("cancelled"), do: "cancelled"
  defp map_status("past_due"), do: "past_due"
  defp map_status("paused"), do: "cancelled"
  defp map_status("expired"), do: "cancelled"
  defp map_status(_), do: "active"
end
