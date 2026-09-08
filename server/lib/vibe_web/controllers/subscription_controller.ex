defmodule VibeWeb.SubscriptionController do
  use VibeWeb, :controller
  alias Vibe.Subscriptions
  alias Vibe.Accounts

  @lemon_squeezy_api_url "https://api.lemonsqueezy.com/v1"

  def list_plans(conn, _params) do
    plans = Subscriptions.list_plans()

    json(conn, %{
      plans:
        Enum.map(plans, fn plan ->
          %{
            id: plan.id,
            name: plan.name,
            priceCents: plan.price_cents,
            interval: plan.interval,
            features: plan.features,
            aiEnabled: plan.ai_features_enabled,
            businessAutoReply: plan.business_auto_reply,
            referralThreshold: plan.referral_threshold
          }
        end)
    })
  end

  def show(conn, %{"user_id" => user_id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
    user = Accounts.get_user(user_id)

    if is_nil(user) do
      conn |> put_status(404) |> json(%{error: "User not found"})
    else
      subscription = Subscriptions.get_user_subscription(user_id)

      json(conn, %{
        tier: user.tier || "free",
        subscription:
          if subscription do
            %{
              id: subscription.id,
              planId: subscription.plan_id,
              planName: subscription.plan.name,
              status: subscription.status,
              currentPeriodEnd: subscription.current_period_end
            }
          else
            nil
          end
      })
    end
    end
  end

  def create_checkout(conn, %{"plan_id" => plan_id} = params) do
    current_id = conn.assigns.current_user.id
    user_id = params["user_id"] || current_id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
    plan = Subscriptions.get_plan(plan_id)
    user = Accounts.get_user(user_id)

    cond do
      is_nil(plan) ->
        conn |> put_status(404) |> json(%{error: "Plan not found"})

      is_nil(user) ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      is_nil(plan.lemon_squeezy_variant_id) ->
        conn |> put_status(400) |> json(%{error: "Plan not available for purchase"})

      true ->
        case create_lemon_squeezy_checkout(plan, user) do
          {:ok, checkout_url} ->
            json(conn, %{checkoutUrl: checkout_url})

          {:error, reason} ->
            conn |> put_status(500) |> json(%{error: "Failed to create checkout", reason: reason})
        end
    end
    end
  end

  def cancel(conn, params) do
    current_id = conn.assigns.current_user.id
    user_id = params["user_id"] || current_id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
    case Subscriptions.get_user_subscription(user_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "No active subscription found"})

      subscription ->
        case cancel_lemon_squeezy_subscription(subscription.lemon_squeezy_subscription_id) do
          {:ok, _} ->
            {:ok, _} = Subscriptions.cancel_subscription(subscription)
            user = Accounts.get_user(user_id)
            new_tier = Subscriptions.calculate_user_tier(user_id)
            Accounts.update_user(user, %{tier: new_tier})
            json(conn, %{success: true, newTier: new_tier})

          {:error, reason} ->
            conn |> put_status(500) |> json(%{error: "Failed to cancel subscription", reason: reason})
        end
    end
    end
  end

  # Lemon Squeezy API Helpers

  defp create_lemon_squeezy_checkout(plan, user) do
    api_key = Application.get_env(:vibe, :lemon_squeezy)[:api_key]
    store_id = Application.get_env(:vibe, :lemon_squeezy)[:store_id]

    body =
      Jason.encode!(%{
        data: %{
          type: "checkouts",
          attributes: %{
            checkout_data: %{
              custom: %{
                user_id: user.id
              },
              email: nil,
              name: user.name || user.username
            }
          },
          relationships: %{
            store: %{data: %{type: "stores", id: store_id}},
            variant: %{data: %{type: "variants", id: plan.lemon_squeezy_variant_id}}
          }
        }
      })

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/vnd.api+json"},
      {"Accept", "application/vnd.api+json"}
    ]

    case :hackney.post("#{@lemon_squeezy_api_url}/checkouts", headers, body, [:with_body]) do
      {:ok, 201, _headers, resp_body} ->
        case Jason.decode(resp_body) do
          {:ok, %{"data" => %{"attributes" => %{"url" => url}}}} ->
            {:ok, url}

          _ ->
            {:error, "Invalid response"}
        end

      {:ok, status, _headers, resp_body} ->
        {:error, "API error: #{status} - #{resp_body}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp cancel_lemon_squeezy_subscription(ls_subscription_id) do
    api_key = Application.get_env(:vibe, :lemon_squeezy)[:api_key]

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Accept", "application/vnd.api+json"}
    ]

    case :hackney.delete(
           "#{@lemon_squeezy_api_url}/subscriptions/#{ls_subscription_id}",
           headers,
           "",
           [:with_body]
         ) do
      {:ok, status, _headers, _body} when status in [200, 204] ->
        {:ok, :cancelled}

      {:ok, status, _headers, resp_body} ->
        {:error, "API error: #{status} - #{resp_body}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
