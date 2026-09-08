defmodule Vibe.SecurityAuthTest do
  @moduledoc "Token lifecycle, logout, profile-update privilege boundary, login throttle."

  use ExUnit.Case, async: false

  alias Vibe.Accounts
  alias Vibe.Accounts.LoginThrottle
  alias Vibe.Accounts.User
  alias Vibe.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    %{user: insert_user("sec")}
  end

  test "a profile update can never set privileged fields", %{user: user} do
    {:ok, updated} =
      Accounts.update_profile(user, %{
        "name" => "New Name",
        "login_token" => "attacker-token",
        "password_hash" => "attacker-hash",
        "tier" => "gold",
        "public_key" => "attacker-key"
      })

    assert updated.name == "New Name"
    assert updated.login_token == user.login_token
    assert updated.password_hash == user.password_hash
    assert updated.tier == user.tier
    assert updated.public_key == user.public_key
  end

  test "sliding expiry cannot outlive the absolute lifetime", %{user: user} do
    far_future = DateTime.utc_now() |> DateTime.add(7 * 86_400, :second) |> DateTime.truncate(:second)
    long_ago = DateTime.utc_now() |> DateTime.add(-400 * 86_400, :second) |> DateTime.truncate(:second)

    {:ok, user} = Accounts.update_user(user, %{"token_expires_at" => far_future, "token_issued_at" => long_ago})
    refute Accounts.token_valid?(user)

    recent = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    {:ok, user} = Accounts.update_user(user, %{"token_issued_at" => recent})
    assert Accounts.token_valid?(user)
  end

  test "revoking the login token invalidates bearer auth", %{user: user} do
    assert {:ok, %User{}} = Accounts.get_user_by_token(user.login_token)
    {:ok, _} = Accounts.revoke_login_token(user)
    assert {:error, _} = Accounts.get_user_by_token(user.login_token)
  end

  test "a device session token authenticates, and stops the moment it is revoked", %{user: user} do
    {:ok, token, session} =
      Accounts.issue_device_session(user.id, %{
        "device_identifier" => "dev-#{System.unique_integer([:positive])}",
        "name" => "Test Device",
        "platform" => "ios"
      })

    assert {:ok, %User{id: id}} = Accounts.get_user_by_token(token)
    assert id == user.id

    assert {:ok, %User{id: ^id}} = Accounts.get_user_by_token(token)

    {:ok, _} = Accounts.revoke_session(user.id, session.id)
    assert {:error, _} = Accounts.get_user_by_token(token)
  end

  test "logout revokes the device session it was called with", %{user: user} do
    {:ok, token, _session} =
      Accounts.issue_device_session(user.id, %{
        "device_identifier" => "dev-#{System.unique_integer([:positive])}",
        "name" => "Test Device",
        "platform" => "ios"
      })

    {:ok, cached} = Accounts.get_user_by_token(token)
    assert {:ok, _} = Accounts.revoke_bearer_token(cached, token)
    assert {:error, _} = Accounts.get_user_by_token(token)
  end

  test "logout revokes a legacy token even when the cached user has it stripped", %{user: user} do
    {:ok, _cold} = Accounts.get_user_by_token(user.login_token)
    {:ok, cached} = Accounts.get_user_by_token(user.login_token)
    refute cached.login_token

    assert {:ok, _} = Accounts.revoke_bearer_token(cached, user.login_token)
    assert {:error, _} = Accounts.get_user_by_token(user.login_token)
  end

  test "login throttle locks after repeated failures and clears on success" do
    id = "throttle_#{System.unique_integer([:positive])}"
    refute LoginThrottle.locked?(id)
    Enum.each(1..10, fn _ -> LoginThrottle.record_failure(id) end)
    assert LoginThrottle.locked?(id)
    LoginThrottle.record_success(id)
    refute LoginThrottle.locked?(id)
  end

  defp insert_user(prefix) do
    suffix = System.unique_integer([:positive])
    token = Ecto.UUID.generate()

    Repo.insert!(%User{
      id: Ecto.UUID.generate(),
      username: "#{prefix}_#{suffix}",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}",
      login_token: token,
      token_expires_at: DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
      token_issued_at: DateTime.utc_now() |> DateTime.truncate(:second),
      tier: "free",
      name: "Sec"
    })
  end
end
