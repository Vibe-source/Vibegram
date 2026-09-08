defmodule Vibe.AI.Tools.Document do
  @moduledoc """
  Document analysis tool for PDFs, text files, etc.
  """

  require Logger
  alias Vibe.Net.SafeURL

  @claude_api "https://api.anthropic.com/v1/messages"
  @claude_model "claude-sonnet-4-20250514"
  @max_chars 100_000  # ~25k tokens, safe for Claude

  @doc """
  Analyze a document and return structured information.
  """
  def analyze(%{"document_url" => url, "task" => task} = params) do
    question = params["question"]

    case fetch_document(url) do
      {:ok, content, doc_type} ->
        prompt = build_prompt(task, question, doc_type)
        analyze_with_claude(content, prompt)

      {:error, reason} ->
        %{error: "Failed to fetch document: #{reason}"}
    end
  end

  defp fetch_document(url) do
    with {:ok, _uri} <- SafeURL.validate(url) do
      case Finch.build(:get, url) |> Finch.request(Vibe.Finch) do
        {:ok, %{status: 200, body: body, headers: headers}} ->
          content_type = get_content_type(headers)

          content = case content_type do
            "application/pdf" ->
              extract_pdf_text(body)

            "text/html" ->
              extract_html_text(body)

            _ ->
              body
          end

          truncated = if String.length(content) > @max_chars do
            String.slice(content, 0, @max_chars) <> "\n\n[Document truncated due to length...]"
          else
            content
          end

          {:ok, truncated, content_type}

        {:ok, %{status: status}} ->
          {:error, "HTTP #{status}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp get_content_type(headers) do
    Enum.find_value(headers, "text/plain", fn
      {"content-type", ct} -> String.split(ct, ";") |> hd()
      _ -> nil
    end)
  end

  defp extract_pdf_text(pdf_binary) do

    text = pdf_binary
      |> :binary.bin_to_list()
      |> to_string()
      |> extract_pdf_strings()

    if String.length(text) < 100 do
      "[PDF content could not be extracted. The document may be image-based or encrypted.]"
    else
      text
    end
  end

  defp extract_pdf_strings(content) do
    Regex.scan(~r/\(([^)]+)\)/, content)
    |> Enum.map(fn [_, text] -> text end)
    |> Enum.join(" ")
    |> String.replace(~r/[\x00-\x1F]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp extract_html_text(html) do
    html
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/is, "")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&nbsp;/, " ")
    |> String.replace(~r/&amp;/, "&")
    |> String.replace(~r/&lt;/, "<")
    |> String.replace(~r/&gt;/, ">")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp build_prompt(task, question, _doc_type) do
    case task do
      "summarize" ->
        """
        Summarize this document concisely. Include:
        - Main topic/purpose
        - Key points (3-5 bullets)
        - Any important conclusions or actions
        """

      "extract_key_points" ->
        """
        Extract the key points from this document as a bullet list.
        Focus on actionable information and important facts.
        """

      "answer_question" when is_binary(question) ->
        """
        Based on the document content, answer this question:
        #{question}

        If the answer isn't in the document, say so.
        """

      _ ->
        "Analyze this document and provide a helpful summary of its contents."
    end
  end

  defp analyze_with_claude(content, prompt) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_API_KEY")

    unless api_key do
      %{error: "ANTHROPIC_API_KEY not configured"}
    else
      body = Jason.encode!(%{
        model: @claude_model,
        max_tokens: 2048,
        messages: [
          %{
            role: "user",
            content: """
            Here is a document to analyze:

            ---DOCUMENT START---
            #{content}
            ---DOCUMENT END---

            #{prompt}
            """
          }
        ]
      })

      headers = [
        {"Content-Type", "application/json"},
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"}
      ]

      case Finch.build(:post, @claude_api, headers, body) |> Finch.request(Vibe.Finch) do
        {:ok, %{status: 200, body: resp_body}} ->
          case Jason.decode(resp_body) do
            {:ok, %{"content" => [%{"text" => text} | _]}} ->
              %{
                success: true,
                analysis: text
              }
            _ ->
              %{error: "Failed to parse response"}
          end

        {:ok, %{status: status, body: resp_body}} ->
          Logger.error("Claude Document error: #{status} - #{resp_body}")
          %{error: "API error: #{status}"}

        {:error, reason} ->
          Logger.error("Claude Document request failed: #{inspect(reason)}")
          %{error: "Request failed"}
      end
    end
  end
end
