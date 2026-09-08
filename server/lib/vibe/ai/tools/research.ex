defmodule Vibe.AI.Tools.Research do
  @moduledoc """
  Web research primitives: `search/1` (find sources) and `read/1` (read one).
  """

  require Logger

  alias Vibe.Net.SafeURL

  @search_url "https://api.tavily.com/search"
  @extract_url "https://api.tavily.com/extract"

  @search_timeout 30_000
  @extract_timeout 45_000
  @direct_fetch_timeout 20_000

  # One page of context, not a book.
  @page_char_limit 12_000
  @snippet_char_limit 1_200
  @max_read_urls 3

  # ── search.

  @doc """
  Search the web. Returns real URLs, per-result relevance scores and publication dates.
  """
  def search(input) when is_map(input) do
    query = string_arg(input, ["query", "q", "search", "message"])

    cond do
      is_nil(query) ->
        %{error: "Missing search query"}

      is_nil(api_key()) ->
        Logger.warning("[Research] TAVILY_API_KEY not configured; falling back to Gemini")
        legacy_search(query)

      true ->
        case tavily_search(query, input) do
          {:ok, result} ->
            result

          {:error, reason} ->
            Logger.warning("[Research] Tavily search failed (#{reason}); falling back to Gemini")
            legacy_search(query)
        end
    end
  end

  def search(_input), do: %{error: "Missing search query"}

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
      |> maybe_put("topic", topic(input))
      |> maybe_put("time_range", time_range(input))
      |> maybe_put("include_domains", domain_list(input, ["include_domains", "includeDomains"]))
      |> maybe_put("exclude_domains", domain_list(input, ["exclude_domains", "excludeDomains"]))
      |> Jason.encode!()

    case post(@search_url, body, @search_timeout) do
      {:ok, %{"results" => results} = response} when is_list(results) ->
        {:ok, format_search(query, results, response)}

      {:ok, response} ->
        Logger.warning("[Research] Unexpected Tavily payload: #{inspect(response) |> String.slice(0, 300)}")
        {:error, "unexpected response"}

      {:error, reason} ->
        {:error, reason}
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
      "shorter or differently-phrased query (drop quotes, drop the year, use the words a " <>
      "publisher would use). If it is still empty, say plainly that you could not find sources."
  end

  defp search_next_step(results, domains) do
    top = results |> Enum.take(3) |> Enum.map(& &1["url"]) |> Enum.reject(&is_nil/1)

    base =
      "These are SNIPPETS, not sources — a snippet is a teaser and is often out of date or " <>
        "out of context. Before you answer anything that depends on specifics (numbers, " <>
        "dates, versions, prices, recommendations, who-said-what), call read_url on the 2–3 " <>
        "most relevant results and answer from the page text."

    coverage =
      case length(domains) do
        n when n <= 1 ->
          " All results are from one domain, so you have one point of view — search again " <>
            "with different wording to find an independent source before you conclude anything."

        _ ->
          " If these results disagree, or leave part of the question unanswered, search again " <>
            "for the missing piece instead of guessing."
      end

    suggestion =
      case top do
        [] -> ""
        urls -> " Suggested reads: " <> Enum.join(urls, ", ") <> "."
      end

    base <> coverage <> suggestion
  end

  defp normalize_result(result) when is_map(result) do
    url = result["url"]

    %{
      "title" => result["title"] || url,
      "url" => url,
      "domain" => domain(url),
      "snippet" => result["content"] |> to_string() |> truncate(@snippet_char_limit),
      "score" => round_score(result["score"]),
      "published_date" => blank_to_nil(result["published_date"])
    }
    |> reject_nil()
  end

  defp normalize_result(result), do: %{"snippet" => to_string(result)}


  @doc """
  Fetch one or more URLs and return their readable text.
  """
  def read(input) when is_map(input) do
    case read_urls(input) do
      {[], _dropped} ->
        %{error: "Missing url"}

      {urls, dropped} ->
        {safe, rejected} = partition_safe(urls)

        if safe == [] do
          %{error: "That URL cannot be fetched: #{rejected |> List.first() |> elem(1)}"}
        else
          safe
          |> Task.async_stream(&read_one/1,
            max_concurrency: @max_read_urls,
            timeout: @extract_timeout + @direct_fetch_timeout + 5_000,
            on_timeout: :kill_task
          )
          |> Enum.zip(safe)
          |> Enum.map(fn
            {{:ok, page}, _url} -> page
            {{:exit, _reason}, url} -> %{"url" => url, "ok" => false, "error" => "timed out"}
          end)
          |> format_read(rejected ++ dropped)
        end
    end
  end

  def read(_input), do: %{error: "Missing url"}

  defp read_urls(input) do
    single = string_arg(input, ["url", "link", "page", "source"])

    list =
      case Map.get(input, "urls") || Map.get(input, :urls) do
        values when is_list(values) -> Enum.map(values, &to_string/1)
        _ -> []
      end

    requested =
      ([single] ++ list)
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    {kept, dropped} = Enum.split(requested, @max_read_urls)

    {kept,
     Enum.map(
       dropped,
       &{&1, "not read — only #{@max_read_urls} pages per call; ask for it in another call"}
     )}
  end

  defp partition_safe(urls) do
    Enum.reduce(urls, {[], []}, fn url, {ok, bad} ->
      case SafeURL.validate(url) do
        {:ok, _uri} -> {ok ++ [url], bad}
        {:error, reason} -> {ok, bad ++ [{url, safe_url_reason(reason)}]}
      end
    end)
  end

  defp safe_url_reason(:invalid_scheme), do: "only http(s) URLs can be read"
  defp safe_url_reason(:missing_host), do: "no host in the URL"
  defp safe_url_reason(:host_not_found), do: "that host does not resolve"
  defp safe_url_reason(:blocked_address), do: "that address is not publicly routable"
  defp safe_url_reason(_), do: "the URL is not valid"

  defp read_one(url) do
    case tavily_extract(url) do
      {:ok, page} ->
        page

      {:error, reason} ->
        Logger.info("[Research] Extract failed for #{url} (#{reason}); trying direct fetch")

        case direct_fetch(url) do
          {:ok, page} -> page
          {:error, direct_reason} -> %{"url" => url, "ok" => false, "error" => direct_reason}
        end
    end
  end

  defp tavily_extract(url) do
    if is_nil(api_key()) do
      {:error, "no Tavily key"}
    else
      body =
        Jason.encode!(%{
          "urls" => [url],
          "extract_depth" => "basic",
          "format" => "markdown"
        })

      case post(@extract_url, body, @extract_timeout) do
        {:ok, %{"results" => [%{"raw_content" => content} = entry | _]}} when is_binary(content) ->
          {:ok, page(entry["url"] || url, nil, content)}

        {:ok, %{"failed_results" => [%{"error" => error} | _]}} ->
          {:error, to_string(error)}

        {:ok, _response} ->
          {:error, "no content extracted"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @max_redirects 3

  defp direct_fetch(url, hops \\ 0)

  defp direct_fetch(url, hops) when hops > @max_redirects do
    {:error, "the page redirected too many times (#{url})"}
  end

  defp direct_fetch(url, hops) do
    headers = [
      {"user-agent",
       "Mozilla/5.0 (compatible; VibeAgent/1.0; +https://vibegram.io) research-reader"},
      {"accept", "text/html,application/xhtml+xml,text/plain;q=0.9"}
    ]

    request = Finch.build(:get, url, headers)

    case Finch.request(request, Vibe.Finch, receive_timeout: @direct_fetch_timeout) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        html = to_string(body)
        {:ok, page(url, extract_title(html), html_to_text(html))}

      {:ok, %{status: status, headers: response_headers}} when status in [301, 302, 303, 307, 308] ->
        case redirect_target(url, response_headers) do
          {:ok, next} -> direct_fetch(next, hops + 1)
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{status: status}} ->
        {:error, "the page returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "the page could not be fetched (#{inspect(reason) |> String.slice(0, 120)})"}
    end
  end

  defp redirect_target(from, headers) do
    location =
      Enum.find_value(headers, fn {name, value} ->
        if String.downcase(name) == "location", do: value
      end)

    case location do
      nil ->
        {:error, "the page redirected without a target"}

      value ->
        absolute = from |> URI.merge(value) |> URI.to_string()

        case SafeURL.validate(absolute) do
          {:ok, _uri} -> {:ok, absolute}
          {:error, reason} -> {:error, "the redirect target is not readable: #{safe_url_reason(reason)}"}
        end
    end
  rescue
    _error -> {:error, "the page redirected to an invalid address"}
  end

  defp page(url, title, content) do
    text = content |> to_string() |> declutter() |> String.trim()
    kept = truncate(text, @page_char_limit)

    %{
      "url" => url,
      "domain" => domain(url),
      "ok" => true,
      "title" => title,
      "content" => kept,
      "words" => text |> String.split(~r/\s+/, trim: true) |> length(),
      "truncated" => String.length(text) > @page_char_limit
    }
    |> reject_nil()
  end

  defp declutter(markdown) do
    markdown
    |> String.replace(~r/!\[[^\]]*\]\([^)]*\)/, "")
    |> String.replace(~r/^\s*\[[^\]]*\]\([^)]*\)\s*$/m, "")
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.replace(~r/[ \t]{2,}/, " ")
  end

  defp format_read(pages, rejected) do
    {read, failed} = Enum.split_with(pages, &(Map.get(&1, "ok") == true))

    rejected_entries =
      Enum.map(rejected, fn {url, reason} -> %{"url" => url, "ok" => false, "error" => reason} end)

    all_failed = failed ++ rejected_entries

    if read == [] do
      %{
        error:
          "Could not read " <>
            (all_failed |> Enum.map(& &1["url"]) |> Enum.join(", ")) <>
            ": " <> (all_failed |> Enum.map(& &1["error"]) |> Enum.uniq() |> Enum.join("; "))
      }
    else
      %{
        "ok" => true,
        "pages" => read,
        "read_count" => length(read),
        "failed" => all_failed,
        "next_step" => read_next_step(read, all_failed)
      }
    end
  end

  defp read_next_step(read, failed) do
    failed_note =
      case failed do
        [] ->
          ""

        entries ->
          " NOT read: " <>
            (entries |> Enum.map(& &1["url"]) |> Enum.join(", ") |> truncate(300)) <>
            " — do not cite a page you did not read."
      end

    truncated? = Enum.any?(read, &(&1["truncated"] == true))

    truncation_note =
      if truncated?, do: " Some pages were truncated; do not claim a page said nothing.", else: ""

    "Answer from these pages, and name the source (publication or domain) for any specific " <>
      "claim you take from them. If a page did not actually answer the question, say what is " <>
      "still missing or search again rather than filling the gap from memory." <>
      failed_note <> truncation_note
  end


  defp legacy_search(query) do
    case Vibe.AI.Tools.Search.gemini(query) do
      {:ok, result} -> result
      {:error, reason} -> %{error: "Search failed: #{reason}"}
    end
  end


  defp post(url, body, timeout) do
    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{api_key()}"}
    ]

    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, Vibe.Finch, receive_timeout: timeout) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        case Jason.decode(response_body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, "could not decode response"}
        end

      {:ok, %{status: 401}} ->
        {:error, "the search key was rejected (401)"}

      {:ok, %{status: 429}} ->
        {:error, "search rate limit reached (429)"}

      {:ok, %{status: status, body: response_body}} ->
        Logger.warning("[Research] HTTP #{status}: #{to_string(response_body) |> String.slice(0, 200)}")
        {:error, "search failed with HTTP #{status}"}

      {:error, reason} ->
        {:error, "search request failed (#{inspect(reason) |> String.slice(0, 120)})"}
    end
  end

  defp api_key do
    case System.get_env("TAVILY_API_KEY") || System.get_env("TAVILY_KEY") do
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

  defp topic(input) do
    case string_arg(input, ["topic"]) do
      value when value in ["general", "news", "finance"] -> value
      _ -> nil
    end
  end

  defp time_range(input) do
    case string_arg(input, ["time_range", "timeRange", "recency"]) do
      value when value in ["day", "week", "month", "year"] -> value
      _ -> nil
    end
  end

  defp domain_list(input, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(input, key) do
        values when is_list(values) and values != [] ->
          values |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.take(10)

        _ ->
          nil
      end
    end)
  end

  defp string_arg(input, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(input, key) || Map.get(input, safe_atom(key)) do
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
          value when is_binary(value) -> case Integer.parse(value) do
            {parsed, _} -> parsed
            :error -> nil
          end
          _ -> nil
        end
      end)

    (value || default) |> max(min) |> min(max)
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
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

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp reject_nil(map) do
    map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp html_to_text(html) do
    html
    |> String.replace(~r/<script\b[^>]*>.*?<\/script>/is, " ")
    |> String.replace(~r/<style\b[^>]*>.*?<\/style>/is, " ")
    |> String.replace(~r/<nav\b[^>]*>.*?<\/nav>/is, " ")
    |> String.replace(~r/<footer\b[^>]*>.*?<\/footer>/is, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> html_decode()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp extract_title(html) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, html) do
      [_, title] -> title |> html_to_text() |> truncate(240) |> blank_to_nil()
      _ -> nil
    end
  end

  defp html_decode(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
  end
end
