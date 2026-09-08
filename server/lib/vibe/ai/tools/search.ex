defmodule Vibe.AI.Tools.Search do
  @moduledoc """
  Gemini-grounded web search — now the FALLBACK path, not the primary one.
  """

  require Logger

  # `gemini-3.0-flash` was retired and every web lookup 404'd ("is not found.
  @default_gemini_model "gemini-2.5-flash"

  @doc """
  Web search.
  """
  def google(params) when is_map(params), do: Vibe.AI.Tools.Research.search(params)
  def google(_params), do: %{error: "Missing search query"}

  @doc """
  Raw Gemini-grounded search. `{:ok, result} | {:error, reason}`.
  """
  def gemini(query) when is_binary(query), do: search_with_gemini(query)
  def gemini(_query), do: {:error, "Missing search query"}

  defp gemini_endpoint do
    model =
      case System.get_env("GEMINI_SEARCH_MODEL") do
        value when is_binary(value) ->
          if String.trim(value) == "", do: @default_gemini_model, else: String.trim(value)

        _ ->
          @default_gemini_model
      end

    "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent"
  end

  defp search_with_gemini(query) do
    api_key = System.get_env("GEMINI_API_KEY")

    if is_nil(api_key) do
      {:error, "No Gemini API key configured"}
    else
      url = "#{gemini_endpoint()}?key=#{api_key}"

      body = Jason.encode!(%{
        contents: [
          %{
            parts: [
              %{
                text: """
                Search the web for: #{query}

                Return the top 5 most relevant results as a JSON array with this exact format:
                [
                  {"title": "Page Title", "url": "https://...", "snippet": "Brief description..."},
                  ...
                ]

                Only return the JSON array, nothing else. No markdown, no explanation.
                """
              }
            ]
          }
        ],
        tools: [
          %{
            google_search: %{}
          }
        ],
        generationConfig: %{
          temperature: 0.1,
          maxOutputTokens: 2048
        }
      })

      headers = [{"Content-Type", "application/json"}]
      request = Finch.build(:post, url, headers, body)

      case Finch.request(request, Vibe.Finch, receive_timeout: 30_000) do
        {:ok, %{status: 200, body: resp_body}} ->
          parse_gemini_response(resp_body, query)

        {:ok, %{status: status, body: resp_body}} ->
          Logger.error("[Search] Gemini API error: #{status} - #{resp_body}")
          {:error, "Gemini API error: #{status}"}

        {:error, reason} ->
          Logger.error("[Search] Gemini request failed: #{inspect(reason)}")
          {:error, "Request failed"}
      end
    end
  end

  defp parse_gemini_response(body, query) do
    case Jason.decode(body) do
      {:ok, %{"candidates" => [%{"content" => %{"parts" => parts}} | _]}} ->
        text_parts = Enum.filter(parts, &Map.has_key?(&1, "text"))
        text = Enum.map_join(text_parts, "", & &1["text"])

        case extract_json_results(text) do
          {:ok, results} ->
            {:ok, %{
              source: "gemini",
              count: length(results),
              results: results,
              query: query
            }}

          {:error, _} ->
            {:ok, %{
              source: "gemini",
              count: 1,
              results: [%{title: "Search Results", snippet: text, url: nil}],
              query: query
            }}
        end

      {:ok, %{"candidates" => [%{"groundingMetadata" => metadata} | _]}} ->
        chunks = Map.get(metadata, "groundingChunks", [])
        results = Enum.map(chunks, fn chunk ->
          web = Map.get(chunk, "web", %{})
          %{
            title: Map.get(web, "title", ""),
            url: Map.get(web, "uri", ""),
            snippet: ""
          }
        end)

        {:ok, %{
          source: "gemini",
          count: length(results),
          results: Enum.take(results, 5),
          query: query
        }}

      {:ok, response} ->
        Logger.warning("[Search] Unexpected Gemini response format: #{inspect(response)}")
        {:error, "Unexpected response format"}

      {:error, reason} ->
        {:error, "Failed to parse response: #{inspect(reason)}"}
    end
  end

  defp extract_json_results(text) do
    trimmed = String.trim(text)

    cleaned = trimmed
    |> String.replace(~r/^```json\s*/, "")
    |> String.replace(~r/^```\s*/, "")
    |> String.replace(~r/\s*```$/, "")
    |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, results} when is_list(results) ->
        formatted = Enum.take(results, 5) |> Enum.map(fn item ->
          %{
            title: item["title"] || "",
            url: item["url"] || "",
            snippet: item["snippet"] || item["description"] || ""
          }
        end)
        {:ok, formatted}

      _ ->
        {:error, "Not valid JSON array"}
    end
  end
end
