defmodule Vibe.ProviderContentTest do
  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.AgentDeliveryEvent
  alias Vibe.ProviderContent
  alias Vibe.Repo
  alias VibeWeb.ChatChannel

  @contract "vibe.content.v1"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp envelope(parts, fallback \\ "fallback body") do
    %{
      "contract" => @contract,
      "fallbackText" => fallback,
      "parts" => parts
    }
  end

  defp part(kind, text, extra \\ %{}) do
    Map.merge(%{"kind" => kind, "text" => text}, extra)
  end

  # ── parse:

  test "parse accepts all 7 core kinds with defaults and trims" do
    raw =
      envelope([
        part("text", "  Hello  ", %{"data" => %{"format" => "markdown"}}),
        part("media", " photo ", %{
          "mediaType" => " image/png ",
          "url" => " https://cdn.example/a.png ",
          "data" => %{"caption" => "cap", "fileName" => "a.png"}
        }),
        part("card", "Card lane", %{
          "data" => %{"title" => "T", "subtitle" => "S", "fields" => []}
        }),
        part("actions", "Choose", %{
          "data" => %{"items" => [%{"id" => "ok", "label" => "OK", "kind" => "button"}]}
        }),
        part("status", "Thinking…", %{"data" => %{"state" => "thinking", "progress" => 0.2}}),
        part("citations", "Sources", %{
          "data" => %{"items" => [%{"title" => "A", "url" => "https://a.example"}]}
        }),
        part("error", "Quota", %{
          "data" => %{"code" => "quota", "message" => "limit", "retryable" => true}
        })
      ])

    assert {:ok, normalized} = ProviderContent.parse(raw)
    assert normalized["contract"] == @contract
    assert normalized["fallbackText"] == "fallback body"
    assert length(normalized["parts"]) == 7

    [text_p, media_p, card_p, actions_p, status_p, cites_p, err_p] = normalized["parts"]

    assert text_p["kind"] == "text"
    assert text_p["text"] == "Hello"
    assert text_p["schemaVersion"] == 1
    assert text_p["required"] == false
    assert text_p["data"]["format"] == "markdown"

    assert media_p["kind"] == "media"
    assert media_p["text"] == "photo"
    assert media_p["mediaType"] == "image/png"
    assert media_p["url"] == "https://cdn.example/a.png"

    assert card_p["kind"] == "card"
    assert actions_p["kind"] == "actions"
    assert status_p["kind"] == "status"
    assert cites_p["kind"] == "citations"
    assert err_p["kind"] == "error"
    assert err_p["required"] == false
  end

  test "parse passes unknown ext kind and preserves extra unknown fields" do
    raw =
      envelope([
        part("com.openai.widget", "Widget fallback", %{
          "schemaVersion" => 2,
          "required" => true,
          "ext" => %{"com.openai.widget" => %{"id" => "w1"}},
          "customTop" => 42
        })
      ])
      |> Map.put("providerMeta", %{"trace" => "abc"})

    assert {:ok, normalized} = ProviderContent.parse(raw)
    assert normalized["providerMeta"] == %{"trace" => "abc"}

    [p] = normalized["parts"]
    assert p["kind"] == "com.openai.widget"
    assert p["text"] == "Widget fallback"
    assert p["schemaVersion"] == 2
    assert p["required"] == true
    assert p["customTop"] == 42
    assert p["ext"]["com.openai.widget"]["id"] == "w1"
  end

  # ── parse:

  test "parse rejects nil and non-map input" do
    assert ProviderContent.parse(nil) == {:error, :invalid_content}
    assert ProviderContent.parse("nope") == {:error, :invalid_content}
    assert ProviderContent.parse([]) == {:error, :invalid_content}
  end

  test "parse rejects unknown contract id" do
    raw = envelope([part("text", "hi")]) |> Map.put("contract", "vibe.content.v0")
    assert {:error, {:invalid_content, :unknown_contract}} = ProviderContent.parse(raw)
  end

  test "parse rejects missing or empty fallbackText" do
    assert {:error, {:invalid_content, :missing_fallback_text}} =
             ProviderContent.parse(%{
               "contract" => @contract,
               "parts" => [part("text", "hi")]
             })

    assert {:error, {:invalid_content, :missing_fallback_text}} =
             ProviderContent.parse(envelope([part("text", "hi")], "   "))
  end

  test "parse rejects parts that are not a list" do
    raw = %{
      "contract" => @contract,
      "fallbackText" => "fb",
      "parts" => %{"kind" => "text", "text" => "x"}
    }

    assert {:error, {:invalid_content, :parts_not_list}} = ProviderContent.parse(raw)
  end

  test "parse rejects missing or empty per-part text lane" do
    assert {:error, {:invalid_content, :missing_part_text}} =
             ProviderContent.parse(envelope([%{"kind" => "text"}]))

    assert {:error, {:invalid_content, :missing_part_text}} =
             ProviderContent.parse(envelope([part("card", "  ")]))
  end

  test "parse rejects part that is not a map or lacks kind" do
    assert {:error, {:invalid_content, :invalid_part}} =
             ProviderContent.parse(envelope(["not-a-map"]))

    assert {:error, {:invalid_content, :missing_part_kind}} =
             ProviderContent.parse(envelope([%{"text" => "hi"}]))
  end

  # ── to_message_attrs ───────────────────────────────────────────────────────

  test "to_message_attrs joins text lanes, skips status, maps media attachments" do
    {:ok, normalized} =
      ProviderContent.parse(
        envelope(
          [
            part("text", "Intro"),
            part("status", "thinking", %{"data" => %{"state" => "thinking"}}),
            part("media", "Image of a cat", %{
              "mediaType" => "image/png",
              "url" => "https://cdn.example/cat.png",
              "data" => %{"caption" => "A cat", "fileName" => "cat.png"}
            }),
            part("card", "Card summary"),
            part("com.ext.chart", "Chart as text")
          ],
          "whole fallback"
        )
      )

    attrs = ProviderContent.to_message_attrs(normalized)

    assert attrs["text"] ==
             "Intro\n\nImage of a cat\n\nCard summary\n\nChart as text"

    assert [att] = attrs["attachments"]
    assert att["mediaType"] == "image/png"
    assert att["mimeType"] == "image/png"
    assert att["url"] == "https://cdn.example/cat.png"
    assert att["caption"] == "A cat"
    assert att["fileName"] == "cat.png"
    assert att["name"] == "cat.png"
    assert att["type"] == "image"
  end

  test "to_message_attrs uses fallbackText when only status parts exist" do
    {:ok, normalized} =
      ProviderContent.parse(
        envelope(
          [part("status", "working", %{"data" => %{"state" => "generating"}})],
          "status-only fallback"
        )
      )

    attrs = ProviderContent.to_message_attrs(normalized)
    assert attrs["text"] == "status-only fallback"
    assert attrs["attachments"] == []
  end

  test "unknown ext kind degrades to its text lane only" do
    {:ok, normalized} =
      ProviderContent.parse(
        envelope([part("com.openai.widget", "Please update the app to view this widget")])
      )

    attrs = ProviderContent.to_message_attrs(normalized)
    assert attrs["text"] == "Please update the app to view this widget"
    assert attrs["attachments"] == []
  end

  # ── vibe.call (registered ext) ─────────────────────────────────────────────

  test "vibe.call part parses and degrades to its text lane" do
    raw =
      envelope([
        part("vibe.call", "Tap to start a voice call with this agent", %{
          "data" => %{"label" => "Call", "mode" => "voice"}
        })
      ])

    assert {:ok, normalized} = ProviderContent.parse(raw)
    [p] = normalized["parts"]
    assert p["kind"] == "vibe.call"
    assert p["text"] == "Tap to start a voice call with this agent"
    assert p["schemaVersion"] == 1
    assert p["required"] == false
    assert p["data"]["label"] == "Call"
    assert p["data"]["mode"] == "voice"

    attrs = ProviderContent.to_message_attrs(normalized)
    assert attrs["text"] == "Tap to start a voice call with this agent"
    assert attrs["attachments"] == []
  end

  # ── capabilities ───────────────────────────────────────────────────────────

  test "capabilities returns negotiation shape with core kinds and vibe.call ext" do
    caps = ProviderContent.capabilities()
    assert caps["version"] == 1
    assert caps["ext"] == ["vibe.call"]

    assert caps["parts"] == [
             "text",
             "media",
             "card",
             "actions",
             "status",
             "citations",
             "error"
           ]
  end

  # ── realtime_voice_capability ──────────────────────────────────────────────

  test "realtime_voice_capability is available when output_modes includes voice" do
    assert ProviderContent.realtime_voice_capability(%{output_modes: ["text", "voice"]}) == %{
             "available" => true,
             "mode" => "callback"
           }

    assert ProviderContent.realtime_voice_capability(%{"output_modes" => ["voice"]}) == %{
             "available" => true,
             "mode" => "callback"
           }
  end

  test "realtime_voice_capability is unavailable without voice mode (nil-safe)" do
    assert ProviderContent.realtime_voice_capability(%{output_modes: ["text"]}) == %{
             "available" => false,
             "mode" => "callback"
           }

    assert ProviderContent.realtime_voice_capability(%{output_modes: nil}) == %{
             "available" => false,
             "mode" => "callback"
           }

    assert ProviderContent.realtime_voice_capability(%{}) == %{
             "available" => false,
             "mode" => "callback"
           }

    assert ProviderContent.realtime_voice_capability(nil) == %{
             "available" => false,
             "mode" => "callback"
           }
  end

  describe "provider interaction delivery" do
    setup do
      owner = insert_user("owner")
      agent_user = insert_user("provider_agent")

      agent =
        Repo.insert!(%Agent{
          owner_user_id: owner.id,
          agent_user_id: agent_user.id,
          status: "published",
          display_name: "Provider Agent",
          callback_url: "https://8.8.8.8/provider-events",
          webhook_secret_hash: "hash",
          secret_hint: "hint"
        })

      %{agent: agent}
    end

    test "queues an action tap with the documented structured payload", %{agent: agent} do
      payload = %{"type" => "action", "actionId" => "approve", "messageId" => "message-1"}

      assert {:ok, delivery} = ChatChannel.deliver_provider_event(agent, "action", payload)
      delivery = AgentDeliveryEvent |> Repo.get!(delivery.id) |> Repo.preload(:invocation)

      assert delivery.event_type == "action"
      assert delivery.request_body == payload
      assert delivery.status == "pending"
      assert delivery.invocation.request_payload == payload
    end

    test "queues call.requested with trusted chat and agent identifiers", %{agent: agent} do
      payload = %{
        "type" => "call.requested",
        "chatId" => "chat-1",
        "agentId" => agent.id
      }

      assert {:ok, delivery} =
               ChatChannel.deliver_provider_event(agent, "call.requested", payload)

      delivery = AgentDeliveryEvent |> Repo.get!(delivery.id) |> Repo.preload(:invocation)
      assert delivery.event_type == "call.requested"
      assert delivery.request_body == payload
      assert delivery.status == "pending"
      assert delivery.invocation.vibe_chat_id == "chat-1"
    end
  end

  defp insert_user(prefix) do
    suffix = System.unique_integer([:positive])

    Repo.insert!(%User{
      id: Ecto.UUID.generate(),
      username: "#{prefix}_#{suffix}",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}"
    })
  end
end
