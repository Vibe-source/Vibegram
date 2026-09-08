defmodule Vibe.SettingsTest do
  use ExUnit.Case, async: true

  alias Vibe.Schemas.NotificationPreference

  test "notification preferences reject unsupported keys" do
    changeset = NotificationPreference.changeset(%NotificationPreference{}, %{
      user_id: Ecto.UUID.generate(),
      preferences: %{"unknown" => true}
    })

    refute changeset.valid?
  end

  # `changeset/2` is the *complete* validator.
  test "notification preferences accept deep partial category updates" do
    updates =
      NotificationPreference.from_wire(%{
        "categories" => %{"private_chats" => %{"enabled" => false}}
      })

    assert {:ok, %{"privateChats" => %{"enabled" => false}}} =
             NotificationPreference.validate_update(updates)
  end

  test "from_wire translates the client payload to the stored shape" do
    updates =
      NotificationPreference.from_wire(%{
        "categories" => %{
          "private_chats" => %{"enabled" => false, "preview" => true, "sound" => true},
          "group_chats" => %{"sound" => false}
        },
        "in_app_sounds" => false,
        "names_on_lock_screen" => true
      })

    assert updates["privateChats"] == %{
             "enabled" => false,
             "preview" => true,
             "sound" => "default"
           }

    assert updates["groupChats"] == %{"sound" => nil}
    assert updates["inAppSounds"] == false
    assert updates["namesOnLockScreen"] == true

    assert {:ok, _} = NotificationPreference.validate_update(updates)
  end

  test "from_wire leaves an already-stored-shape payload alone" do
    updates = NotificationPreference.from_wire(%{"privateChats" => %{"enabled" => false}})

    assert updates == %{"privateChats" => %{"enabled" => false}}
    assert {:ok, _} = NotificationPreference.validate_update(updates)
  end

  test "to_wire round-trips back into what the client reads" do
    wire =
      NotificationPreference.default_preferences()
      |> NotificationPreference.to_wire()

    assert %{"categories" => categories} = wire
    assert categories["private_chats"] == %{"enabled" => true, "preview" => true, "sound" => true}
    assert wire["in_app_sounds"] == true

    silent =
      %{"privateChats" => %{"enabled" => true, "preview" => true, "sound" => nil}}
      |> NotificationPreference.to_wire()

    assert silent["categories"]["private_chats"]["sound"] == false
  end
end
