defmodule Vibe.MessageReportTest do
  @moduledoc "Message report validation, persistence, and blocking tests."

  use ExUnit.Case, async: false

  alias Vibe.Accounts
  alias Vibe.Accounts.{User, UserBlock}
  alias Vibe.Chat
  alias Vibe.Chat.{Message, MessageReaction, MessageReport, MessageView}
  alias Vibe.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    author = insert_user("report_author")
    reporter = insert_user("report_reporter")
    {:ok, room} = Chat.create_group(author.id, "Reports", [reporter.id])
    message = insert_message(room.id, author.id)

    %{author: author, reporter: reporter, chat_id: room.id, message: message}
  end

  test "persists a pending report with ids and reason only", context do
    %{author: author, reporter: reporter, chat_id: chat_id, message: message} = context

    assert {:ok, %{report: report, blocked: false}} =
             Chat.report_message(chat_id, message.id, reporter.id, %{
               "reason" => "spam",
               "details" => "  posted the same link ten times  "
             })

    assert report.status == "pending"
    assert report.reason == "spam"
    assert report.details == "posted the same link ten times"
    assert report.chat_id == chat_id
    assert report.message_id == message.id
    assert report.reporter_id == reporter.id
    assert report.reported_user_id == author.id
    assert is_nil(report.reviewer_id)
    assert is_nil(report.reviewed_at)
    assert is_nil(report.resolved_at)

    stored = report |> Map.from_struct() |> Map.drop([:__meta__])
    refute Enum.any?(Map.values(stored), &(&1 == message.encrypted_content))
    refute Map.has_key?(stored, :encrypted_content)
  end

  test "accepts every frozen reason and rejects anything else", context do
    %{reporter: reporter, chat_id: chat_id, message: message} = context

    assert Chat.report_reasons() == ~w(spam violence abuse sexual_content copyright
             personal_data other)

    Enum.each(Chat.report_reasons(), fn reason ->
      assert {:ok, %{report: report}} =
               Chat.report_message(chat_id, message.id, reporter.id, %{"reason" => reason})

      assert report.reason == reason
    end)

    assert {:error, :invalid_reason} =
             Chat.report_message(chat_id, message.id, reporter.id, %{"reason" => "vibes"})

    assert {:error, :invalid_reason} =
             Chat.report_message(chat_id, message.id, reporter.id, %{})

    assert {:ok, %{report: %{reason: "sexual_content"}}} =
             Chat.report_message(chat_id, message.id, reporter.id, %{
               "reason" => "Sexual-Content"
             })
  end

  test "bounds details and refuses a self-report or a foreign reporter", context do
    %{author: author, reporter: reporter, chat_id: chat_id, message: message} = context
    outsider = insert_user("report_outsider")

    assert {:error, :details_too_long} =
             Chat.report_message(chat_id, message.id, reporter.id, %{
               "reason" => "spam",
               "details" => String.duplicate("x", 1001)
             })

    assert {:error, :invalid_target} =
             Chat.report_message(chat_id, message.id, author.id, %{"reason" => "spam"})

    assert {:error, :forbidden} =
             Chat.report_message(chat_id, message.id, outsider.id, %{"reason" => "spam"})

    assert {:error, :not_found} =
             Chat.report_message(chat_id, Ecto.UUID.generate(), reporter.id, %{"reason" => "spam"})

    assert {:error, :invalid_id} =
             Chat.report_message(chat_id, "not-a-uuid", reporter.id, %{"reason" => "spam"})

    assert Repo.aggregate(MessageReport, :count) == 0
  end

  test "blockSender blocks the author and stays accurate when re-reported", context do
    %{author: author, reporter: reporter, chat_id: chat_id, message: message} = context

    assert {:ok, %{blocked: true}} =
             Chat.report_message(chat_id, message.id, reporter.id, %{
               "reason" => "abuse",
               "blockSender" => true
             })

    assert Accounts.blocked?(reporter.id, author.id)
    assert Repo.aggregate(UserBlock, :count) == 1

    assert {:ok, %{blocked: true}} =
             Chat.report_message(chat_id, message.id, reporter.id, %{
               "reason" => "abuse",
               "blockSender" => true
             })

    assert Repo.aggregate(UserBlock, :count) == 1
    assert Repo.aggregate(MessageReport, :count) == 2

    assert {:ok, %{blocked: true}} =
             Chat.report_message(chat_id, message.id, reporter.id, %{"reason" => "spam"})
  end

  test "a report without blockSender leaves the sender unblocked", context do
    %{author: author, reporter: reporter, chat_id: chat_id, message: message} = context

    assert {:ok, %{blocked: false}} =
             Chat.report_message(chat_id, message.id, reporter.id, %{
               "reason" => "other",
               "blockSender" => false
             })

    refute Accounts.blocked?(reporter.id, author.id)
    assert Repo.aggregate(UserBlock, :count) == 0
  end

  test "the report outlives the message while reactions and views cascade", context do
    %{author: author, reporter: reporter, chat_id: chat_id, message: message} = context

    assert {:ok, _} = Chat.toggle_reaction(chat_id, message.id, reporter.id, "👍")
    assert {:ok, _} = Chat.mark_messages_viewed(chat_id, reporter.id, [message.id])

    assert {:ok, %{report: report}} =
             Chat.report_message(chat_id, message.id, reporter.id, %{"reason" => "violence"})

    assert {:ok, _} = Chat.delete_message(chat_id, message.id, author.id, true)

    assert Repo.aggregate(MessageReaction, :count) == 0
    assert Repo.aggregate(MessageView, :count) == 0

    surviving = Repo.get!(MessageReport, report.id)
    assert is_nil(surviving.message_id)
    assert surviving.source_message_id == message.id
    assert surviving.chat_id == chat_id
    assert surviving.reported_user_id == author.id
    assert surviving.reason == "violence"
  end

  test "the controller answers with the created report and an accurate blocked flag", context do
    %{author: author, reporter: reporter, chat_id: chat_id, message: message} = context

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.assign(:current_user, reporter)
      |> VibeWeb.ChatController.report_message(%{
        "chat_id" => chat_id,
        "message_id" => message.id,
        "reason" => "personal_data",
        "blockSender" => true
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert body["success"] == true
    assert body["blocked"] == true
    assert body["report"]["reason"] == "personal_data"
    assert body["report"]["messageId"] == message.id
    assert body["report"]["chatId"] == chat_id
    assert body["report"]["status"] == "pending"
    assert body["report"]["reportedUserId"] == author.id
    refute Map.has_key?(body["report"], "encryptedContent")

    rejected =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.assign(:current_user, reporter)
      |> VibeWeb.ChatController.report_message(%{
        "chat_id" => chat_id,
        "message_id" => message.id,
        "reason" => "vibes"
      })

    assert rejected.status == 400
    assert Jason.decode!(rejected.resp_body)["reasons"] == Chat.report_reasons()
  end

  test "the report route exists and rejects an unauthenticated call", %{
    chat_id: chat_id,
    message: message
  } do
    route =
      Enum.find(VibeWeb.Router.__routes__(), fn route ->
        route.verb == :post and route.path == "/api/chat/:chat_id/messages/:message_id/report"
      end)

    assert route
    assert route.plug == VibeWeb.ChatController
    assert route.plug_opts == :report_message

    conn =
      Phoenix.ConnTest.dispatch(
        Phoenix.ConnTest.build_conn(),
        VibeWeb.Endpoint,
        :post,
        "/api/chat/#{chat_id}/messages/#{message.id}/report",
        %{"reason" => "spam"}
      )

    assert conn.status == 401
    assert Repo.aggregate(MessageReport, :count) == 0
  end

  defp insert_message(chat_id, from_id) do
    Repo.insert!(%Message{
      id: Ecto.UUID.generate(),
      chat_id: chat_id,
      from_id: from_id,
      encrypted_content: "sealed-report-body",
      timestamp: System.system_time(:millisecond)
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
