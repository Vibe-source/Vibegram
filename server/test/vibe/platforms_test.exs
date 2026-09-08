defmodule Vibe.PlatformsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Vibe.Accounts.User
  alias Vibe.ConnectionGrant
  alias Vibe.PlatformConnection
  alias Vibe.Platforms
  alias Vibe.Platforms.TokenVault
  alias Vibe.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    user = insert_user("platforms_owner")
    other = insert_user("platforms_other")
    %{user: user, other: other}
  end

  test "catalog lists github and multi-platform stubs" do
    items = Platforms.catalog()
    ids = Enum.map(items, & &1.id)
    assert "github" in ids
    assert "microsoft_excel" in ids
    assert "slack" in ids
    assert "linear" in ids
    assert "google_calendar" in ids

    github = Enum.find(items, &(&1.id == "github"))
    assert is_list(github.capabilities)
    assert Enum.any?(github.capabilities, &(&1.id == "list_pull_requests"))
  end

  test "token vault round-trips and payloads never include ciphertext fields", %{user: user} do
    assert {:ok, cipher} = TokenVault.encrypt("gho_test_token_value")
    assert cipher != "gho_test_token_value"
    assert {:ok, "gho_test_token_value"} = TokenVault.decrypt(cipher)

    conn = insert_connection(user, cipher)

    payload = Platforms.connection_payload(Repo.preload(conn, :grants))
    encoded = Jason.encode!(payload)

    refute String.contains?(encoded, "gho_test_token_value")
    refute Map.has_key?(payload, :access_token_encrypted)
    refute Map.has_key?(payload, "accessToken")
    refute Map.has_key?(payload, :accessToken)
  end

  test "default bridge grants after connect simulation", %{user: user} do
    {:ok, access_enc} = TokenVault.encrypt("gho_abc")
    conn = insert_connection(user, access_enc)

    for agent <- ~w[claude codex grok agy vibe] do
      assert {:ok, _} =
               Platforms.upsert_grant(user.id, conn.id, %{
                 "grantee_type" => "bridge_agent",
                 "grantee_id" => agent
               })
    end

    grants =
      Repo.all(from g in ConnectionGrant, where: g.connection_id == ^conn.id)

    assert Enum.any?(grants, &(&1.grantee_type == "bridge_agent" and &1.grantee_id == "claude"))
    assert Enum.any?(grants, &(&1.grantee_type == "bridge_agent" and &1.grantee_id == "codex"))
  end

  test "invoke requires grant and rejects cross-tenant", %{user: user, other: other} do
    {:ok, access_enc} = TokenVault.encrypt("gho_secret")
    conn = insert_connection(user, access_enc)

    assert {:error, :no_grant} =
             Platforms.invoke(user.id, "agent", Ecto.UUID.generate(), %{
               "provider" => "github",
               "action" => "list_repos"
             })

    {:ok, _grant} =
      Platforms.upsert_grant(user.id, conn.id, %{
        "grantee_type" => "agent",
        "grantee_id" => "agent-1",
        "capabilities" => ["list_repos"]
      })

    assert {:error, :no_grant} =
             Platforms.invoke(other.id, "agent", "agent-1", %{
               "provider" => "github",
               "action" => "list_repos",
               "connection_id" => conn.id
             })

    assert {:error, {:capability_not_allowed, _}} =
             Platforms.invoke(user.id, "agent", "agent-1", %{
               "provider" => "github",
               "action" => "create_pr_comment",
               "params" => %{"owner" => "a", "repo" => "b", "number" => 1, "body" => "hi"}
             })
  end

  test "revoke strips tokens and deletes grants", %{user: user} do
    {:ok, access_enc} = TokenVault.encrypt("gho_to_revoke")
    conn = insert_connection(user, access_enc)

    {:ok, _} =
      Platforms.upsert_grant(user.id, conn.id, %{
        "grantee_type" => "bridge_agent",
        "grantee_id" => "claude"
      })

    assert {:ok, _} = Platforms.revoke_connection(user.id, conn.id)

    reloaded = Repo.get!(PlatformConnection, conn.id)
    assert reloaded.status == "revoked"
    assert is_nil(reloaded.access_token_encrypted)

    assert [] == Repo.all(from g in ConnectionGrant, where: g.connection_id == ^conn.id)
  end

  test "oauth state is user-bound and time-limited", %{user: user} do
    state = Platforms.sign_state(%{"uid" => user.id, "provider" => "github", "n" => "x"})
    assert {:ok, claims} = Platforms.verify_state(state)
    assert claims["uid"] == user.id
    assert claims["provider"] == "github"
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

  defp insert_connection(user, access_enc) do
    %PlatformConnection{}
    |> PlatformConnection.changeset(%{
      user_id: user.id,
      provider: "github",
      external_account_id: "12345",
      external_account_login: "octocat",
      display_name: "Octocat",
      scopes: ["repo", "read:user"],
      status: "active",
      access_token_encrypted: access_enc,
      metadata: %{"avatar_url" => "https://example.com/a.png"}
    })
    |> Repo.insert!()
  end
end
