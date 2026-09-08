defmodule VibeWeb.UserPrivacyTest do
  use ExUnit.Case, async: false

  alias Vibe.Accounts
  alias Vibe.Accounts.User
  alias Vibe.Chat
  alias Vibe.Repo
  alias VibeWeb.PushAvatarController
  alias VibeWeb.UserController

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    owner =
      insert_user("privacy_owner", %{
        phone_number: unique_phone(),
        bio: "secret bio",
        profile_image: "https://cdn.example/owner.png",
        date_of_birth: ~D[1990-01-15],
        privacy_phone_number: "nobody",
        privacy_bio: "nobody",
        privacy_profile_photos: "nobody",
        privacy_birthday: "nobody"
      })

    stranger = insert_user("privacy_stranger")
    %{owner: owner, stranger: stranger}
  end

  test "strangers do not receive hidden profile fields", %{owner: owner, stranger: stranger} do
    body = show_user(stranger, owner.id)

    assert body["userId"] == owner.id
    assert body["username"] == owner.username
    assert body["bio"] == nil
    assert body["profileImage"] == nil
    assert body["dateOfBirth"] == nil
    assert body["phoneNumber"] == nil
  end

  test "the owner still sees their own hidden fields", %{owner: owner} do
    body = show_user(owner, owner.id)

    assert body["bio"] == "secret bio"
    assert body["profileImage"] == "https://cdn.example/owner.png"
    assert body["dateOfBirth"] == "1990-01-15"
    assert body["phoneNumber"] == owner.phone_number
  end

  test "phone lookup 404s when the number is not visible to the viewer", %{
    owner: owner,
    stranger: stranger
  } do
    conn = call_phone(stranger, owner.phone_number)
    assert conn.status == 404
  end

  test "a DM contact can see contacts-only fields", %{owner: owner, stranger: stranger} do
    {:ok, owner} =
      Accounts.update_user(owner, %{
        privacy_bio: "contacts",
        privacy_profile_photos: "contacts",
        privacy_birthday: "contacts",
        privacy_phone_number: "contacts"
      })

    assert {:ok, _chat_id, _} = Chat.ensure_dm_chat(owner.id, stranger.id)

    body = show_user(stranger, owner.id)
    assert body["bio"] == "secret bio"
    assert body["profileImage"] == "https://cdn.example/owner.png"
    assert body["dateOfBirth"] == "1990-01-15"
    assert body["phoneNumber"] == owner.phone_number
  end

  test "push avatars are withheld when profile photos are not public", %{owner: owner} do
    conn =
      Plug.Test.conn(:get, "/api/push/avatar/#{owner.id}")
      |> PushAvatarController.show(%{"user_id" => owner.id})

    assert conn.status == 404
  end

  defp show_user(viewer, id) do
    conn =
      Plug.Test.conn(:get, "/api/user/#{id}")
      |> Plug.Conn.assign(:current_user, viewer)
      |> UserController.show(%{"id" => id})

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp call_phone(viewer, phone) do
    Plug.Test.conn(:get, "/api/user/phone/#{phone}")
    |> Plug.Conn.assign(:current_user, viewer)
    |> UserController.show_by_phone(%{"phone" => phone})
  end

  defp insert_user(prefix, attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    defaults = %{
      id: Ecto.UUID.generate(),
      username: "#{prefix}_#{suffix}",
      name: "Privacy #{suffix}",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}",
      is_agent: false
    }

    Repo.insert!(struct(User, Map.merge(defaults, Map.new(attrs))))
  end

  defp unique_phone do
    "1555#{System.unique_integer([:positive]) |> rem(10_000_000) |> Integer.to_string() |> String.pad_leading(7, "0")}"
  end
end
