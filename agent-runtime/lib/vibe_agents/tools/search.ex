defmodule VibeAgents.Tools.Search do
  @moduledoc """
  Ported from `server/lib/vibe/ai/tools/research.ex` `search/1` (Tavily). No Gemini
  fallback here — a missing `TAVILY_API_KEY` returns a readable "not configured" error.
  """
  require Logger

  @search_url "https://api.tavily.com/search"
  @search_timeout 30_000

  def search_google(input) when is_map(input) do
    query = string_arg(input, ["query", "q", "search", "message"])

    cond do
      is_nil(query) -> %{"ok" => false, "error" => "Missing search query"}
      is_nil(api_key()) -> %{"ok" => false, "error" => "Web search is not configured (TAVILY_API_KEY missing)."}
      true -> tavily_search(query, input)
    end
  end

  def search_google(_input), do: %{"ok" => false, "error" => "Missing search query"}

  defp tavily_search(query, input) do
    body =
      %{
        "query" => query,
        "search_depth" => search_depth(input),
        "max_results" => int_arg(input, ["max_results", "maxResults"], 6, 1, 12),
        "include_answer" => false,
        "include_raw_content" => false,
        "include_images" => false
      }
      |> maybe_put("time_range", time_range(input))
      |> Jason.encode!()

    case post(@search_url, body, @search_timeout) do
      {:ok, %{"results" => results} = response} when is_list(results) ->
        format_search(query, results, response)

      {:ok, response} ->
        Logger.warning("[VibeAgents.Tools.Search] Unexpected Tavily payload: #{inspect(response) |> String.slice(0, 300)}")
        %{"ok" => false, "error" => "Search returned an unexpected response."}

      {:error, reason} ->
        %{"ok" => false, "error" => "Search failed: #{reason}"}
    end
  end

  defp format_search(query, results, response) do
    normalized = Enum.map(results, &normalize_result/1)
    domains = normalized |> Enum.map(& &1["domain"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      "ok" => true,
      "provider" => "tavily",
      "query" => response["query"] || query,
      "count" => length(normalized),
      "results" => normalized,
      "domains" => domains,
      "next_step" => search_next_step(normalized, domains)
    }
  end

  defp search_next_step([], _domains) do
    "No results. Do NOT answer from memory as if you had searched. Retry once with a " <>
      "shorter or differently-phrased query. If it is still empty, say plainly that you " <>
      "could not find sources."
  end

  defp search_next_step(results, domains) do
    top = results |> Enum.take(3) |> Enum.map(& &1["url"]) |> Enum.reject(&is_nil/1)

    base =
      "These are SNIPPETS, not sources. Before you answer anything that depends on " <>
        "specifics, call read_url on the 2–3 most relevant results and answer from the page text."

    coverage =
      case length(domains) do
        n when n <= 1 -> " All results are from one domain — search again with different wording."
        _ -> " If these results disagree, search again for the missing piece instead of guessing."
      end

    suggestion = if top == [], do: "", else: " Suggested reads: " <> Enum.join(top, ", ") <> "."
    base <> coverage <> suggestion
  end

  defp normalize_result(result) when is_map(result) do
    url = result["url"]

    %{
      "title" => result["title"] || url,
      "url" => url,
      "domain" => domain(url),
      "snippet" => result["content"] |> to_string() |> truncate(1_200),
      "score" => round_score(result["score"]),
      "published_date" => blank_to_nil(result["published_date"])
    }
    |> reject_nil()
  end

  defp normalize_result(result), do: %{"snippet" => to_string(result)}

  defp post(url, body, timeout) do
    headers = [{"content-type", "application/json"}, {"authorization", "Bearer #{api_key()}"}]
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, VibeAgents.Finch, receive_timeout: timeout) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        case Jason.decode(response_body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, "could not decode response"}
        end

      {:ok, %{status: 401}} -> {:error, "the search key was rejected (401)"}
      {:ok, %{status: 429}} -> {:error, "search rate limit reached (429)"}
      {:ok, %{status: status}} -> {:error, "search failed with HTTP #{status}"}
      {:error, reason} -> {:error, "search request failed (#{inspect(reason) |> String.slice(0, 120)})"}
    end
  end

  defp api_key do
    case System.get_env("TAVILY_API_KEY") do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: String.trim(value)
      _ -> nil
    end
  end

  defp search_depth(input) do
    case string_arg(input, ["search_depth", "searchDepth", "depth"]) do
      "advanced" -> "advanced"
      _ -> "basic"
    end
  end

  defp time_range(input) do
    case string_arg(input, ["time_range", "timeRange", "recency"]) do
      value when value in ["day", "week", "month", "year"] -> value
      _ -> nil
    end
  end

  defp string_arg(input, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(input, key) do
        value when is_binary(value) -> if String.trim(value) == "", do: nil, else: String.trim(value)
        _ -> nil
      end
    end)
  end

  defp int_arg(input, keys, default, min, max) do
    value =
      Enum.find_value(keys, fn key ->
        case Map.get(input, key) do
          value when is_integer(value) -> value
          value when is_binary(value) -> (case Integer.parse(value) do
            {parsed, _} -> parsed
            :error -> nil
          end)
          _ -> nil
        end
      end)

    (value || default) |> max(min) |> min(max)
  end

  defp domain(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.replace_prefix(host, "www.", "")
      _ -> nil
    end
  end

  defp domain(_url), do: nil

  defp truncate(text, limit) do
    text = to_string(text)
    if String.length(text) > limit, do: String.slice(text, 0, limit) <> "…", else: text
  end

  defp round_score(score) when is_float(score), do: Float.round(score, 3)
  defp round_score(score) when is_integer(score), do: score
  defp round_score(_score), do: nil

  defp blank_to_nil(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp blank_to_nil(_value), do: nil

  defp reject_nil(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
