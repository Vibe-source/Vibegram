defmodule VibeAgents.Tools.ReadUrl do
  @moduledoc "Ported from `server/lib/vibe/ai/tools/research.ex` `read/1`, using VibeContracts.SafeURL."
  require Logger

  @extract_url "https://api.tavily.com/extract"
  @extract_timeout 45_000
  @direct_fetch_timeout 20_000
  @page_char_limit 12_000
  @max_read_urls 3
  @max_redirects 3

  def read_url(input) when is_map(input) do
    case read_urls(input) do
      {[], _dropped} ->
        %{"error" => "Missing url"}

      {urls, dropped} ->
        {safe, rejected} = partition_safe(urls)

        if safe == [] do
          %{"error" => "That URL cannot be fetched: #{rejected |> List.first() |> elem(1)}"}
        else
          safe
          |> Task.async_stream(&read_one/1, max_concurrency: @max_read_urls, timeout: @extract_timeout + @direct_fetch_timeout + 5_000, on_timeout: :kill_task)
          |> Enum.zip(safe)
          |> Enum.map(fn
            {{:ok, page}, _url} -> page
            {{:exit, _reason}, url} -> %{"url" => url, "ok" => false, "error" => "timed out"}
          end)
          |> format_read(rejected ++ dropped)
        end
    end
  end

  def read_url(_input), do: %{"error" => "Missing url"}

  defp read_urls(input) do
    single = string_arg(input, ["url", "link", "page", "source"])

    list =
      case Map.get(input, "urls") do
        values when is_list(values) -> Enum.map(values, &to_string/1)
        _ -> []
      end

    requested = ([single] ++ list) |> Enum.reject(&(is_nil(&1) or &1 == "")) |> Enum.uniq()
    {kept, dropped} = Enum.split(requested, @max_read_urls)
    {kept, Enum.map(dropped, &{&1, "not read — only #{@max_read_urls} pages per call; ask for it in another call"})}
  end

  defp partition_safe(urls) do
    Enum.reduce(urls, {[], []}, fn url, {ok, bad} ->
      case VibeContracts.SafeURL.validate(url) do
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
        Logger.info("[VibeAgents.Tools.ReadUrl] Extract failed for #{url} (#{reason}); trying direct fetch")

        case direct_fetch(url) do
          {:ok, page} -> page
          {:error, direct_reason} -> %{"url" => url, "ok" => false, "error" => direct_reason}
        end
    end
  end

  defp tavily_extract(url) do
    case tavily_api_key() do
      nil ->
        {:error, "no Tavily key"}

      key ->
        body = Jason.encode!(%{"urls" => [url], "extract_depth" => "basic", "format" => "markdown"})
        headers = [{"content-type", "application/json"}, {"authorization", "Bearer #{key}"}]
        request = Finch.build(:post, @extract_url, headers, body)

        case Finch.request(request, VibeAgents.Finch, receive_timeout: @extract_timeout) do
          {:ok, %{status: status, body: response_body}} when status in 200..299 ->
            parse_extract(response_body, url)

          {:ok, %{status: status}} ->
            {:error, "extract failed with HTTP #{status}"}

          {:error, reason} ->
            {:error, inspect(reason) |> String.slice(0, 120)}
        end
    end
  end

  defp parse_extract(body, url) do
    case Jason.decode(body) do
      {:ok, %{"results" => [%{"raw_content" => content} = entry | _]}} when is_binary(content) ->
        {:ok, page(entry["url"] || url, nil, content)}

      {:ok, %{"failed_results" => [%{"error" => error} | _]}} ->
        {:error, to_string(error)}

      _ ->
        {:error, "no content extracted"}
    end
  end

  defp direct_fetch(url, hops \\ 0)
  defp direct_fetch(url, hops) when hops > @max_redirects, do: {:error, "the page redirected too many times (#{url})"}

  defp direct_fetch(url, hops) do
    headers = [
      {"user-agent", "Mozilla/5.0 (compatible; VibeAgent/1.0; +https://vibegram.io) research-reader"},
      {"accept", "text/html,application/xhtml+xml,text/plain;q=0.9"}
    ]

    request = Finch.build(:get, url, headers)

    case Finch.request(request, VibeAgents.Finch, receive_timeout: @direct_fetch_timeout) do
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
    location = Enum.find_value(headers, fn {name, value} -> if String.downcase(name) == "location", do: value end)

    case location do
      nil ->
        {:error, "the page redirected without a target"}

      value ->
        absolute = from |> URI.merge(value) |> URI.to_string()

        case VibeContracts.SafeURL.validate(absolute) do
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
    rejected_entries = Enum.map(rejected, fn {url, reason} -> %{"url" => url, "ok" => false, "error" => reason} end)
    all_failed = failed ++ rejected_entries

    if read == [] do
      %{
        "error" =>
          "Could not read " <>
            (all_failed |> Enum.map(& &1["url"]) |> Enum.join(", ")) <>
            ": " <> (all_failed |> Enum.map(& &1["error"]) |> Enum.uniq() |> Enum.join("; "))
      }
    else
      %{"ok" => true, "pages" => read, "read_count" => length(read), "failed" => all_failed, "next_step" => read_next_step(read, all_failed)}
    end
  end

  defp read_next_step(read, failed) do
    failed_note =
      case failed do
        [] -> ""
        entries -> " NOT read: " <> (entries |> Enum.map(& &1["url"]) |> Enum.join(", ") |> truncate(300)) <> " — do not cite a page you did not read."
      end

    truncated? = Enum.any?(read, &(&1["truncated"] == true))
    truncation_note = if truncated?, do: " Some pages were truncated; do not claim a page said nothing.", else: ""

    "Answer from these pages, and name the source (publication or domain) for any specific " <>
      "claim you take from them. If a page did not actually answer the question, say what is " <>
      "still missing or search again rather than filling the gap from memory." <> failed_note <> truncation_note
  end

  defp tavily_api_key do
    case System.get_env("TAVILY_API_KEY") do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: String.trim(value)
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

  defp reject_nil(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

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

  defp blank_to_nil(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp blank_to_nil(_value), do: nil

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
