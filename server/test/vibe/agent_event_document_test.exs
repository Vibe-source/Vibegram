defmodule Vibe.AgentEventDocumentTest do
  @moduledoc """
  A document arriving from an event has to reach the chat as ONE cell: the file with the event
  summary as its caption.
  """
  use ExUnit.Case, async: true

  alias Vibe.AI.AgentEventRuntime

  describe "merged_attachment_caption/2" do
    test "the event summary becomes the caption when the file brought none" do
      assert AgentEventRuntime.merged_attachment_caption(
               "# Container ready\n\nTY3103",
               %{"url" => "https://example.test/TY3103.pdf"}
             ) == "# Container ready\n\nTY3103"
    end

    test "keeps both texts when the file brought its own caption" do
      merged =
        AgentEventRuntime.merged_attachment_caption(
          "# Container ready",
          %{"caption" => "Manifest for TY3103"}
        )

      assert merged == "# Container ready\n\nManifest for TY3103"
    end

    test "does not repeat a caption the summary already contains" do
      assert AgentEventRuntime.merged_attachment_caption(
               "# Container ready\n\nManifest for TY3103",
               %{"caption" => "Manifest for TY3103"}
             ) == "# Container ready\n\nManifest for TY3103"
    end

    test "falls back to the file's own caption, then to nothing" do
      assert AgentEventRuntime.merged_attachment_caption(nil, %{"title" => "Manifest"}) ==
               "Manifest"

      assert AgentEventRuntime.merged_attachment_caption("  ", %{}) == nil
    end
  end

  describe "attachment_file_name/1" do
    test "prefers the declared name" do
      assert AgentEventRuntime.attachment_file_name(%{
               "name" => "manifest.pdf",
               "url" => "https://example.test/raw/9f2c1a.pdf"
             }) == "manifest.pdf"
    end

    test "derives a name from the url when the sender omitted one" do
      assert AgentEventRuntime.attachment_file_name(%{
               "url" => "https://example.test/print/container/1.pdf?sig=abc&exp=123"
             }) == "1.pdf"
    end

    test "decodes percent-escapes so the cell shows a readable name" do
      assert AgentEventRuntime.attachment_file_name(%{
               "url" => "https://example.test/docs/%D8%A8%D8%A7%D8%B1%D9%86%D8%A7%D9%85%D9%87.pdf"
             }) == "بارنامه.pdf"
    end

    test "returns nil rather than a bogus name for a pathless url" do
      assert AgentEventRuntime.attachment_file_name(%{"url" => "https://example.test"}) == nil
      assert AgentEventRuntime.attachment_file_name(%{}) == nil
    end

    test "an extensionless path is not a file name" do
      assert AgentEventRuntime.attachment_file_name(%{
               "url" => "https://example.test/print/container/2?exp=1&sig=a"
             }) == nil

      assert AgentEventRuntime.attachment_file_name(%{
               "url" => "https://example.test/print/container/2",
               "name" => "manifest.html"
             }) == "manifest.html"
    end
  end

  describe "attachment_mime_type/1" do
    test "trusts the declared type" do
      assert AgentEventRuntime.attachment_mime_type(%{
               "mimeType" => "application/pdf",
               "url" => "https://example.test/x.png"
             }) == "application/pdf"
    end

    test "infers from the extension so the cell can show a type before download" do
      assert AgentEventRuntime.attachment_mime_type(%{"url" => "https://example.test/a/b.pdf"}) ==
               "application/pdf"

      assert AgentEventRuntime.attachment_mime_type(%{"name" => "sheet.XLSX"}) ==
               "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    end

    test "stays nil for an extension it cannot place" do
      assert AgentEventRuntime.attachment_mime_type(%{"url" => "https://example.test/blob"}) == nil
    end
  end

  describe "normalize_event_attachments/1 feeding the document contract" do
    test "a cargo pdf ends up with a name and a pdf mime type" do
      assert %{"items" => [pdf]} =
               AgentEventRuntime.normalize_event_attachments(%{
                 "attachments" => [
                   %{"url" => "https://cargo.test/print/container/12.pdf?sig=deadbeef"}
                 ]
               })

      assert AgentEventRuntime.attachment_file_name(pdf) == "12.pdf"
      assert AgentEventRuntime.attachment_mime_type(pdf) == "application/pdf"
    end
  end
end
