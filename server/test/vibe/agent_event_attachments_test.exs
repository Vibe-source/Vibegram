defmodule Vibe.AgentEventAttachmentsTest do
  use ExUnit.Case, async: true

  alias Vibe.AI.AgentEventRuntime

  test "normalizes frozen nested cargo attachment fields" do
    assert %{"items" => [image, pdf]} =
             AgentEventRuntime.normalize_event_attachments(%{
               "data" => %{
                 "attachments" => [
                   %{
                     "type" => "image",
                     "title" => "Cargo sheet",
                     "filename" => "123456.png",
                     "mime" => "image/png",
                     "url" => "https://example.test/123456.png"
                   },
                   %{
                     "type" => "pdf",
                     "filename" => "123456.pdf",
                     "mime" => "application/pdf",
                     "url" => "https://example.test/123456.pdf"
                   }
                 ]
               }
             })

    assert image["name"] == "123456.png"
    assert image["mimeType"] == "image/png"
    assert image["caption"] == "Cargo sheet"
    assert pdf["name"] == "123456.pdf"
    assert pdf["mimeType"] == "application/pdf"
  end

  test "keeps top-level attachments compatible and merges nested attachments" do
    assert %{"items" => [top, nested]} =
             AgentEventRuntime.normalize_event_attachments(%{
               "attachments" => [
                 %{"type" => "image", "url" => "https://example.test/top.png"}
               ],
               "payload" => %{
                 "attachments" => [
                   %{"type" => "html", "url" => "https://example.test/print.html"}
                 ]
               }
             })

    assert top["type"] == "image"
    assert nested["type"] == "html"
  end

  test "drops malformed, unsafe, and overlong attachment URLs" do
    long_url = "https://example.test/" <> String.duplicate("a", 2_100)

    assert %{"items" => [kept]} =
             AgentEventRuntime.normalize_event_attachments(%{
               "attachments" => [
                 "not-a-map",
                 %{"url" => "file:///etc/passwd"},
                 %{"url" => "javascript:alert(1)"},
                 %{"url" => long_url},
                 %{"url" => "https://example.test/safe.pdf"}
               ]
             })

    assert kept["url"] == "https://example.test/safe.pdf"
  end

  test "caps normalized attachments to ten items" do
    attachments =
      for i <- 1..12 do
        %{"url" => "https://example.test/#{i}.png"}
      end

    assert %{"items" => items} =
             AgentEventRuntime.normalize_event_attachments(%{"attachments" => attachments})

    assert length(items) == 10
    assert List.last(items)["url"] == "https://example.test/10.png"
  end
end
