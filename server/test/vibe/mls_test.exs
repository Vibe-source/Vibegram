defmodule Vibe.MlsTest do
  @moduledoc """
  MLS KeyPackage publish/claim: round trip, single-use claiming, exhaustion,
  concurrent-claim atomicity, and publish scoping.
  """

  use ExUnit.Case, async: false

  alias Vibe.Accounts
  alias Vibe.Accounts.User
  alias Vibe.Chat
  alias Vibe.Mls
  alias Vibe.Repo
  alias Vibe.Schemas.MlsKeyPackage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    user = insert_user("mls_owner")
    %{user: user}
  end

  test "publish then claim returns one of the published packages", %{user: user} do
    packages = for i <- 1..3, do: fake_key_package(i)

    assert {:ok, %{count: 3}} =
             Mls.publish_key_packages(user.id, %{
               "deviceId" => "device-a",
               "keyPackages" => packages
             })

    assert {:ok, claimed} = Mls.claim_key_package(user.id)
    assert claimed.device_id == "device-a"
    assert Base.encode64(claimed.key_package) in packages
    refute is_nil(claimed.claimed_at)
  end

  test "claiming twice never returns the same package", %{user: user} do
    packages = for i <- 1..2, do: fake_key_package(i)

    {:ok, _} =
      Mls.publish_key_packages(user.id, %{"deviceId" => "device-a", "keyPackages" => packages})

    assert {:ok, first} = Mls.claim_key_package(user.id)
    assert {:ok, second} = Mls.claim_key_package(user.id)

    refute first.id == second.id
    refute first.key_package == second.key_package

    reloaded = Repo.get!(MlsKeyPackage, first.id)
    refute is_nil(reloaded.claimed_at)
  end

  test "a stranger cannot claim another user's KeyPackage", %{user: user} do
    {:ok, _} =
      Mls.publish_key_packages(user.id, %{
        "deviceId" => "device-a",
        "keyPackages" => [fake_key_package(1)]
      })

    stranger = insert_user("mls_stranger")
    assert {:error, :not_allowed} = Mls.claim_key_package(stranger.id, user.id)
    assert Mls.count_available(user.id) == 1
  end

  test "a chat peer can claim one KeyPackage", %{user: user} do
    {:ok, _} =
      Mls.publish_key_packages(user.id, %{
        "deviceId" => "device-a",
        "keyPackages" => [fake_key_package(1)]
      })

    peer = insert_user("mls_peer")
    chat_id = "chat-claim-#{System.unique_integer([:positive])}"
    {:ok, _} = Chat.create_chat(chat_id, [user.id, peer.id])

    assert {:ok, claimed} = Mls.claim_key_package(peer.id, user.id)
    assert claimed.user_id == user.id
    assert Mls.count_available(user.id) == 0
  end

  test "a blocked peer cannot claim a KeyPackage even with a shared chat", %{user: user} do
    {:ok, _} =
      Mls.publish_key_packages(user.id, %{
        "deviceId" => "device-a",
        "keyPackages" => [fake_key_package(1)]
      })

    peer = insert_user("mls_blocked_peer")
    chat_id = "chat-claim-block-#{System.unique_integer([:positive])}"
    {:ok, _} = Chat.create_chat(chat_id, [user.id, peer.id])
    {:ok, _} = Accounts.block_user(user.id, peer.id)

    assert {:error, :not_allowed} = Mls.claim_key_package(peer.id, user.id)
    assert Mls.count_available(user.id) == 1
  end

  test "one peer cannot drain another user's KeyPackage pool", %{user: user} do
    packages = for i <- 1..10, do: fake_key_package(i)

    {:ok, _} =
      Mls.publish_key_packages(user.id, %{
        "deviceId" => "device-a",
        "keyPackages" => packages
      })

    peer = insert_user("mls_drain")
    chat_id = "chat-claim-drain-#{System.unique_integer([:positive])}"
    {:ok, _} = Chat.create_chat(chat_id, [user.id, peer.id])

    for _ <- 1..8 do
      assert {:ok, _} = Mls.claim_key_package(peer.id, user.id)
    end

    assert {:error, :too_many} = Mls.claim_key_package(peer.id, user.id)
    assert Mls.count_available(user.id) == 2
  end

  test "claiming when none remain returns not-found, no crash", %{user: user} do
    assert {:error, :not_found} = Mls.claim_key_package(user.id)

    {:ok, _} =
      Mls.publish_key_packages(user.id, %{
        "deviceId" => "device-a",
        "keyPackages" => [fake_key_package(1)]
      })

    assert {:ok, _} = Mls.claim_key_package(user.id)
    assert {:error, :not_found} = Mls.claim_key_package(user.id)
  end

  test "concurrency: N parallel claims hand out N distinct packages", %{user: user} do
    n = 20
    packages = for i <- 1..n, do: fake_key_package(i)

    {:ok, %{count: ^n}} =
      Mls.publish_key_packages(user.id, %{"deviceId" => "device-a", "keyPackages" => packages})

    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

    results =
      1..n
      |> Task.async_stream(fn _ -> Mls.claim_key_package(user.id) end,
        max_concurrency: n,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert length(results) == n
    assert Enum.all?(results, &match?({:ok, _}, &1))

    claimed_ids = Enum.map(results, fn {:ok, package} -> package.id end)
    claimed_bins = Enum.map(results, fn {:ok, package} -> package.key_package end)

    assert length(Enum.uniq(claimed_ids)) == n
    assert length(Enum.uniq(claimed_bins)) == n
    assert MapSet.new(claimed_bins) == MapSet.new(Enum.map(packages, &Base.decode64!/1))

    assert {:error, :not_found} = Mls.claim_key_package(user.id)
  end

  test "a user cannot publish on behalf of another user", %{user: user} do
    victim = insert_user("mls_victim")

    assert {:ok, %{count: 1}} =
             Mls.publish_key_packages(user.id, %{
               "userId" => victim.id,
               "deviceId" => "attacker-device",
               "keyPackages" => [fake_key_package(1)]
             })

    assert Mls.count_available(user.id) == 1
    assert Mls.count_available(victim.id) == 0

    {:ok, claimed} = Mls.claim_key_package(user.id)
    assert claimed.device_id == "attacker-device"
    assert {:error, :not_found} = Mls.claim_key_package(victim.id)
  end

  test "an over-large batch is rejected outright, not truncated", %{user: user} do
    too_many = for i <- 1..101, do: fake_key_package(i)

    assert {:error, :batch_too_large} =
             Mls.publish_key_packages(user.id, %{
               "deviceId" => "device-a",
               "keyPackages" => too_many
             })

    assert Mls.count_available(user.id) == 0
  end

  test "rejects a non-base64 keyPackage entry", %{user: user} do
    assert {:error, :invalid_key_package_encoding} =
             Mls.publish_key_packages(user.id, %{
               "deviceId" => "device-a",
               "keyPackages" => ["not-valid-base64!!"]
             })

    assert Mls.count_available(user.id) == 0
  end

  test "rejects a missing or blank deviceId", %{user: user} do
    assert {:error, :invalid_device_id} =
             Mls.publish_key_packages(user.id, %{"keyPackages" => [fake_key_package(1)]})

    assert {:error, :invalid_device_id} =
             Mls.publish_key_packages(user.id, %{
               "deviceId" => "   ",
               "keyPackages" => [fake_key_package(1)]
             })
  end


  defp fake_key_package(label) do
    Base.encode64("mls-keypkg-#{label}-#{System.unique_integer([:positive])}")
  end


  test "retiring drops this device's unclaimed packages and leaves only the fresh batch", %{
    user: user
  } do
    stale = for i <- 1..3, do: fake_key_package("stale-#{i}")

    {:ok, _} =
      Mls.publish_key_packages(user.id, %{"deviceId" => "device-a", "keyPackages" => stale})

    fresh = for i <- 1..2, do: fake_key_package("fresh-#{i}")

    assert {:ok, %{count: 2}} =
             Mls.publish_key_packages(user.id, %{
               "deviceId" => "device-a",
               "keyPackages" => fresh,
               "retireDeviceKeys" => true
             })

    assert Mls.count_available(user.id) == 2

    for _ <- 1..2 do
      assert {:ok, claimed} = Mls.claim_key_package(user.id)
      assert Base.encode64(claimed.key_package) in fresh
    end

    assert {:error, :not_found} = Mls.claim_key_package(user.id)
  end

  test "retiring leaves another device's packages alone", %{user: user} do
    other_device = for i <- 1..2, do: fake_key_package("other-#{i}")

    {:ok, _} =
      Mls.publish_key_packages(user.id, %{"deviceId" => "device-b", "keyPackages" => other_device})

    {:ok, _} =
      Mls.publish_key_packages(user.id, %{
        "deviceId" => "device-a",
        "keyPackages" => [fake_key_package("fresh")],
        "retireDeviceKeys" => true
      })

    assert Mls.count_available(user.id) == 3
  end

  test "retiring leaves a claimed package's record intact", %{user: user} do
    {:ok, _} =
      Mls.publish_key_packages(user.id, %{
        "deviceId" => "device-a",
        "keyPackages" => [fake_key_package("spent")]
      })

    {:ok, spent} = Mls.claim_key_package(user.id)

    {:ok, _} =
      Mls.publish_key_packages(user.id, %{
        "deviceId" => "device-a",
        "keyPackages" => [fake_key_package("fresh")],
        "retireDeviceKeys" => true
      })

    assert Repo.get(MlsKeyPackage, spent.id)
  end

  test "retiring drops pending welcomes addressed to this user", %{user: user} do
    sender = insert_user("mls_sender")
    {:ok, _} = post_welcome(sender.id, user.id, "chat-1")
    assert [_pending] = Mls.pending_welcomes(user.id)

    {:ok, _} =
      Mls.publish_key_packages(user.id, %{
        "deviceId" => "device-a",
        "keyPackages" => [fake_key_package("fresh")],
        "retireDeviceKeys" => true
      })

    assert [] = Mls.pending_welcomes(user.id)
  end

  test "retiring does not touch welcomes this user sent to someone else", %{user: user} do
    recipient = insert_user("mls_recipient")
    {:ok, _} = post_welcome(user.id, recipient.id, "chat-1")

    {:ok, _} =
      Mls.publish_key_packages(user.id, %{
        "deviceId" => "device-a",
        "keyPackages" => [fake_key_package("fresh")],
        "retireDeviceKeys" => true
      })

    assert [_still_pending] = Mls.pending_welcomes(recipient.id)
  end

  test "the response says whether the retirement actually happened", %{user: user} do
    assert {:ok, %{retired: false}} =
             Mls.publish_key_packages(user.id, %{
               "deviceId" => "device-a",
               "keyPackages" => [fake_key_package("plain")]
             })

    assert {:ok, %{retired: true}} =
             Mls.publish_key_packages(user.id, %{
               "deviceId" => "device-a",
               "keyPackages" => [fake_key_package("fresh")],
               "retireDeviceKeys" => true
             })
  end

  test "publishing without the flag retires nothing", %{user: user} do
    {:ok, _} =
      Mls.publish_key_packages(user.id, %{
        "deviceId" => "device-a",
        "keyPackages" => [fake_key_package("first")]
      })

    {:ok, _} =
      Mls.publish_key_packages(user.id, %{
        "deviceId" => "device-a",
        "keyPackages" => [fake_key_package("second")]
      })

    assert Mls.count_available(user.id) == 2
  end


  test "a welcome round-trips to its recipient", %{user: sender} do
    recipient = insert_user("mls_recipient")

    assert {:ok, _row} = post_welcome(sender.id, recipient.id, "chat-1")

    assert [pending] = Mls.pending_welcomes(recipient.id)
    assert pending.chat_id == "chat-1"
    assert pending.sender_user_id == sender.id
    assert pending.welcome == "welcome-bytes"
    assert pending.ratchet_tree == "tree-bytes"
  end

  test "a welcome notifies the recipient's lowercase topic even for an uppercase id", %{
    user: sender
  } do
    recipient = insert_user("mls_upper")
    chat_id = "chat-case-#{System.unique_integer([:positive])}"
    {:ok, _} = Chat.create_chat(chat_id, [sender.id, recipient.id])
    VibeWeb.Endpoint.subscribe("user:#{recipient.id}")

    {:ok, _} =
      Mls.post_welcome(sender.id, %{
        "recipientUserId" => String.upcase(recipient.id),
        "chatId" => chat_id,
        "welcome" => Base.encode64("welcome-bytes")
      })

    assert_receive %Phoenix.Socket.Broadcast{event: "mls_welcome", payload: %{chatId: ^chat_id}}
  end

  test "acking a welcome notifies the sender so their queued message flushes", %{user: sender} do
    recipient = insert_user("mls_acker")
    chat_id = "chat-ack-#{System.unique_integer([:positive])}"
    {:ok, _} = post_welcome(sender.id, recipient.id, chat_id)
    [pending] = Mls.pending_welcomes(recipient.id)
    VibeWeb.Endpoint.subscribe("user:#{sender.id}")

    assert :ok = Mls.ack_welcome(recipient.id, pending.id)

    assert_receive %Phoenix.Socket.Broadcast{
      event: "mls_welcome_acked",
      payload: %{chatId: ^chat_id}
    }
  end

  test "a body-supplied senderUserId is ignored in favour of the authenticated user", %{
    user: sender
  } do
    recipient = insert_user("mls_recipient")
    impostor = insert_user("mls_impostor")
    {:ok, _} = Chat.create_chat("chat-1", [sender.id, recipient.id])

    {:ok, _} =
      Mls.post_welcome(sender.id, %{
        "recipientUserId" => recipient.id,
        "senderUserId" => impostor.id,
        "chatId" => "chat-1",
        "welcome" => Base.encode64("welcome-bytes")
      })

    assert [pending] = Mls.pending_welcomes(recipient.id)
    assert pending.sender_user_id == sender.id
  end

  test "one user cannot read another user's pending welcome", %{user: sender} do
    recipient = insert_user("mls_recipient")
    outsider = insert_user("mls_outsider")

    {:ok, _} = post_welcome(sender.id, recipient.id, "chat-1")

    assert [_one] = Mls.pending_welcomes(recipient.id)
    assert [] = Mls.pending_welcomes(outsider.id)
  end

  test "one user cannot ack another user's welcome", %{user: sender} do
    recipient = insert_user("mls_recipient")
    outsider = insert_user("mls_outsider")

    {:ok, row} = post_welcome(sender.id, recipient.id, "chat-1")

    assert {:error, :not_found} = Mls.ack_welcome(outsider.id, row.id)
    assert [_one] = Mls.pending_welcomes(recipient.id)

    assert :ok = Mls.ack_welcome(recipient.id, row.id)
    assert [] = Mls.pending_welcomes(recipient.id)
  end

  test "acking twice is not an error the second time it is a miss", %{user: sender} do
    recipient = insert_user("mls_recipient")
    {:ok, row} = post_welcome(sender.id, recipient.id, "chat-1")

    assert :ok = Mls.ack_welcome(recipient.id, row.id)
    assert {:error, :not_found} = Mls.ack_welcome(recipient.id, row.id)
  end

  test "a malformed id is a miss rather than a crash", %{user: recipient} do
    assert {:error, :not_found} = Mls.ack_welcome(recipient.id, "not-a-uuid")
  end

  test "an oversize welcome is rejected rather than stored", %{user: sender} do
    recipient = insert_user("mls_recipient")
    {:ok, _} = Chat.create_chat("chat-1", [sender.id, recipient.id])

    oversize = Base.encode64(:crypto.strong_rand_bytes(256 * 1024 + 1))

    assert {:error, :too_large} =
             Mls.post_welcome(sender.id, %{
               "recipientUserId" => recipient.id,
               "chatId" => "chat-1",
               "welcome" => oversize
             })

    assert [] = Mls.pending_welcomes(recipient.id)
  end

  test "non-base64 welcome bytes are rejected", %{user: sender} do
    recipient = insert_user("mls_recipient")
    {:ok, _} = Chat.create_chat("chat-1", [sender.id, recipient.id])

    assert {:error, :invalid_encoding} =
             Mls.post_welcome(sender.id, %{
               "recipientUserId" => recipient.id,
               "chatId" => "chat-1",
               "welcome" => "!!!not base64!!!"
             })
  end

  test "one sender cannot pile up unlimited welcomes for one recipient", %{user: sender} do
    recipient = insert_user("mls_recipient")

    for i <- 1..20 do
      assert {:ok, _} = post_welcome(sender.id, recipient.id, "chat-#{i}")
    end

    assert {:error, :too_many_pending} = post_welcome(sender.id, recipient.id, "chat-21")

    other_sender = insert_user("mls_other_sender")
    assert {:ok, _} = post_welcome(other_sender.id, recipient.id, "chat-22")
  end

  test "welcome_status counts sent and received rows separately", %{user: sender} do
    recipient = insert_user("mls_joiner")
    outsider = insert_user("mls_outsider")
    chat_id = "chat-status-1"

    {:ok, row} = post_welcome(sender.id, recipient.id, chat_id)

    assert Mls.welcome_status(sender.id, chat_id) == %{
             pending: 1,
             delivered: 0,
             incoming_pending: 0,
             incoming_delivered: 0
           }

    assert Mls.welcome_status(recipient.id, chat_id) == %{
             pending: 0,
             delivered: 0,
             incoming_pending: 1,
             incoming_delivered: 0
           }

    assert Mls.welcome_status(outsider.id, chat_id) == %{
             pending: 0,
             delivered: 0,
             incoming_pending: 0,
             incoming_delivered: 0
           }

    assert :ok = Mls.ack_welcome(recipient.id, row.id)

    assert Mls.welcome_status(sender.id, chat_id) == %{
             pending: 0,
             delivered: 1,
             incoming_pending: 0,
             incoming_delivered: 0
           }

    assert Mls.welcome_status(recipient.id, chat_id) == %{
             pending: 0,
             delivered: 0,
             incoming_pending: 0,
             incoming_delivered: 1
           }
  end

  test "a non-member sender cannot post a welcome", %{user: sender} do
    recipient = insert_user("mls_recipient")
    chat_id = "chat-gate-sender-#{System.unique_integer([:positive])}"
    {:ok, _} = Chat.create_chat(chat_id, [recipient.id])

    assert {:error, :not_allowed} =
             Mls.post_welcome(sender.id, %{
               "recipientUserId" => recipient.id,
               "chatId" => chat_id,
               "welcome" => Base.encode64("welcome-bytes")
             })

    assert [] = Mls.pending_welcomes(recipient.id)
  end

  test "a welcome for a non-member recipient is refused", %{user: sender} do
    recipient = insert_user("mls_recipient")
    chat_id = "chat-gate-recipient-#{System.unique_integer([:positive])}"
    {:ok, _} = Chat.create_chat(chat_id, [sender.id])

    assert {:error, :not_allowed} =
             Mls.post_welcome(sender.id, %{
               "recipientUserId" => recipient.id,
               "chatId" => chat_id,
               "welcome" => Base.encode64("welcome-bytes")
             })

    assert [] = Mls.pending_welcomes(recipient.id)
  end

  defp post_welcome(sender_id, recipient_id, chat_id) do
    {:ok, _} = Chat.create_chat(chat_id, [sender_id, recipient_id])

    Mls.post_welcome(sender_id, %{
      "recipientUserId" => recipient_id,
      "chatId" => chat_id,
      "welcome" => Base.encode64("welcome-bytes"),
      "ratchetTree" => Base.encode64("tree-bytes")
    })
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
