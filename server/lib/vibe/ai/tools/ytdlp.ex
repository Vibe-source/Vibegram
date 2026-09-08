defmodule Vibe.AI.Tools.YtDlp do
  @moduledoc """
  yt-dlp wrapper for extracting audio streams from YouTube and other platforms.
  """

  require Logger

  # 30 seconds max per request (fast mode should be <5s)
  @timeout 30_000
  @download_timeout 120_000

  @doc """
  Search for music and get stream URL.
  Returns {:ok, track_info} or {:error, reason}
  """
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 3)

    search_query = "ytsearch#{limit}:#{query}"

    base_args = [
      "--no-download",
      "--print-json",
      "--flat-playlist",
      "--no-warnings",
      "--ignore-errors",
      "--extractor-retries",
      "2",
      "--socket-timeout",
      "10",
      "--user-agent",
      random_user_agent(),
      "--referer",
      "https://www.youtube.com/"
    ]

    args =
      case get_cookies_path() do
        nil -> base_args ++ [search_query]
        path -> base_args ++ ["--cookies", path, search_query]
      end

    case run_ytdlp(args) do
      {:ok, output} ->
        tracks = parse_search_results(output)
        {:ok, tracks}

      {:error, reason} ->
        Logger.error("[YtDlp] Search failed: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  Get detailed info including stream URL for a specific video or page URL (YouTube, SoundCloud,
  and other yt-dlp extractors).
  """
  def get_stream_url(video_id_or_url) do
    url = normalize_url(video_id_or_url)

    if String.starts_with?(url, "http") do
      case safe_media_url(url) do
        {:ok, _} ->
          do_get_stream_url(url)

        {:error, reason} ->
          Logger.warning(
            "[YtDlp] blocked non-music/unsafe URL host=#{inspect(safe_host(url))} reason=#{inspect(reason)}"
          )

          {:error, "unsupported_or_unsafe_url"}
      end
    else
      do_get_stream_url(url)
    end
  end

  defp do_get_stream_url(url) do
    base_args =
      [
        "--no-download",
        "--print-json",
        "-f",
        "bestaudio/bestaudio*/best",
        "--no-playlist",
        "--no-warnings",
        "--extractor-retries",
        "3",
        "--user-agent",
        random_user_agent(),
        "--referer",
        referer_for(url),
        "--add-header",
        "Accept-Language:en-US,en;q=0.9"
      ] ++ player_client_args()

    args =
      case get_cookies_path() do
        nil -> base_args ++ ["--", url]
        path -> base_args ++ ["--cookies", path, "--", url]
      end

    case run_ytdlp(args) do
      {:ok, output} ->
        case first_json_object(output) do
          {:ok, data} ->
            {:ok, track_from_ytdlp_data(data, url)}

          {:error, _} ->
            {:error, "Failed to parse response"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resolve a share URL (SoundCloud, YouTube, …) into one playable track card.
  Same as `get_stream_url/1` but named for the agent music tool path.
  """
  def resolve_url(url) when is_binary(url), do: get_stream_url(url)
  def resolve_url(_), do: {:error, "invalid_url"}

  @doc """
  True when the string looks like a music page URL the agent should resolve
  instead of running a YouTube text search.
  """
  def music_page_url?(value) when is_binary(value) do
    trimmed = String.trim(value)

    with true <-
           String.starts_with?(trimmed, "http://") or String.starts_with?(trimmed, "https://"),
         %URI{host: host} when is_binary(host) <- URI.parse(trimmed) do
      host = String.downcase(host)

      String.contains?(host, "soundcloud.com") or
        String.contains?(host, "youtube.com") or
        String.contains?(host, "youtu.be") or
        String.contains?(host, "music.youtube.com") or
        String.contains?(host, "on.soundcloud.com") or
        String.contains?(host, "bandcamp.com") or
        String.contains?(host, "vimeo.com") or
        String.contains?(host, "mixcloud.com")
    else
      _ -> false
    end
  end

  def music_page_url?(_), do: false

  @music_hosts ~w(
    soundcloud.com youtube.com youtu.be bandcamp.com vimeo.com mixcloud.com
  )

  @doc """
  SSRF gate for any URL handed to yt-dlp. `{:ok.
  """
  def safe_media_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    with %URI{scheme: scheme, host: host}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <-
           URI.parse(trimmed),
         true <- allowed_music_host?(host),
         {:ok, _} <- Vibe.Net.SafeURL.validate(trimmed) do
      {:ok, trimmed}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :host_not_allowed}
      _ -> {:error, :invalid_url}
    end
  end

  def safe_media_url(_), do: {:error, :invalid_url}

  defp allowed_music_host?(host) do
    h = host |> String.downcase() |> String.trim_trailing(".")
    Enum.any?(@music_hosts, fn d -> h == d or String.ends_with?(h, "." <> d) end)
  end

  defp safe_host(url) do
    case URI.parse(url) do
      %URI{host: host} -> host
      _ -> nil
    end
  end

  @doc """
  Best URL to hand yt-dlp for a cached track id (YouTube id, sc_*, or stored webpage).
  """
  def download_url_for_track_id(track_id, opts \\ []) when is_binary(track_id) do
    links = Keyword.get(opts, :links) || %{}
    source = Keyword.get(opts, :source)

    cond do
      is_binary(links["webpage_url"]) and links["webpage_url"] != "" ->
        links["webpage_url"]

      is_binary(links[:webpage_url]) and links[:webpage_url] != "" ->
        links[:webpage_url]

      is_binary(links["soundcloud"]) and links["soundcloud"] != "" ->
        links["soundcloud"]

      is_binary(links["youtube"]) and links["youtube"] != "" ->
        links["youtube"]

      String.starts_with?(track_id, "sc_") ->
        track_id

      String.starts_with?(track_id, "http") ->
        track_id

      source == "soundcloud" ->
        track_id

      true ->
        "https://www.youtube.com/watch?v=#{track_id}"
    end
  end

  @doc """
  Search and get full stream info in one call (for caching).
  Returns list of tracks with stream URLs.
  """
  def search_with_streams(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 3)

    search_query = "ytsearch#{limit}:#{query}"

    base_args =
      [
        "--no-download",
        "--print-json",
        "-f",
        "bestaudio/bestaudio*/best",
        "--no-warnings",
        "--ignore-errors",
        "--extractor-retries",
        "3",
        "--sleep-requests",
        "1",
        "--user-agent",
        random_user_agent(),
        "--referer",
        "https://www.youtube.com/",
        "--add-header",
        "Accept-Language:en-US,en;q=0.9",
        "--add-header",
        "Accept:text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
      ] ++ player_client_args()

    args =
      case get_cookies_path() do
        nil -> base_args ++ [search_query]
        path -> base_args ++ ["--cookies", path, search_query]
      end

    case run_ytdlp(args) do
      {:ok, output} ->
        tracks = parse_full_results(output)
        {:ok, tracks}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_ytdlp(args), do: run_cmd(args)

  @doc """
  Run yt-dlp with the given CLI args.
  """
  def run_cmd(args, opts \\ [])

  def run_cmd(args, opts) when is_list(args) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    case runner() do
      nil ->
        Logger.error(
          "[YtDlp] yt-dlp not found (install binary or `pip install yt-dlp`; set YTDLP_PATH)"
        )

        {:error, "yt-dlp not available"}

      {cmd, cmd_args, label} ->
        full_args = cmd_args ++ args
        Logger.info("[YtDlp] Running: #{label} #{Enum.join(args, " ")}")

        task =
          Task.async(fn ->
            try do
              case System.cmd(cmd, full_args, stderr_to_stdout: true) do
                {output, 0} ->
                  {:ok, output}

                {output, code} ->
                  Logger.warning("[YtDlp] Exit code #{code}: #{String.slice(output, 0, 500)}")
                  if String.contains?(output, "\"id\":") do
                    {:ok, output}
                  else
                    {:error, "yt-dlp exited with code #{code}"}
                  end
              end
            rescue
              e ->
                Logger.error("[YtDlp] Exception: #{inspect(e)}")
                {:error, "yt-dlp not available"}
            end
          end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          nil -> {:error, "Timeout after #{timeout}ms"}
        end
    end
  end

  def run_cmd(_, _), do: {:error, "invalid_args"}

  @doc """
  Absolute path to the `yt-dlp` binary, or nil if only the Python module is available.
  """
  def executable do
    env =
      System.get_env("YTDLP_PATH") ||
        System.get_env("VIBE_YTDLP_PATH")

    candidates =
      [
        env,
        System.find_executable("yt-dlp"),
        System.find_executable("youtube-dl"),
        "/opt/homebrew/bin/yt-dlp",
        "/usr/local/bin/yt-dlp",
        "/usr/bin/yt-dlp",
        Path.expand("~/Library/Python/3.12/bin/yt-dlp"),
        Path.expand("~/Library/Python/3.11/bin/yt-dlp"),
        Path.expand("~/Library/Python/3.10/bin/yt-dlp"),
        Path.expand("~/Library/Python/3.9/bin/yt-dlp"),
        Path.expand("~/.local/bin/yt-dlp")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))

    Enum.find(candidates, fn path ->
      is_binary(path) and File.regular?(path) and File.exists?(path)
    end)
  end

  defp runner do
    case executable() do
      bin when is_binary(bin) ->
        {bin, [], bin}

      nil ->
        case python3_executable() do
          py when is_binary(py) ->
            if python_has_ytdlp?(py) do
              {py, ["-m", "yt_dlp"], "#{py} -m yt_dlp"}
            else
              nil
            end

          _ ->
            nil
        end
    end
  end

  defp python3_executable do
    [
      System.get_env("PYTHON_PATH"),
      System.find_executable("python3"),
      System.find_executable("python"),
      "/usr/local/bin/python3",
      "/usr/bin/python3"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.find(fn path -> File.exists?(path) end)
  end

  defp python_has_ytdlp?(python) when is_binary(python) do
    case System.cmd(python, ["-c", "import yt_dlp"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp parse_search_results(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, data} ->
          %{
            video_id: data["id"],
            title: data["title"],
            artist: data["uploader"] || data["channel"],
            duration: format_duration(data["duration"]),
            duration_seconds: data["duration"],
            cover: data["thumbnail"] || data["thumbnails"] |> List.first() |> then(& &1["url"]),
            url: "https://www.youtube.com/watch?v=#{data["id"]}"
          }

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_full_results(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, data} ->
          thumbnail =
            case data["thumbnail"] do
              nil -> get_best_thumbnail(data["thumbnails"])
              url -> url
            end

          %{
            video_id: data["id"],
            title: data["title"],
            artist: data["uploader"] || data["channel"],
            duration: format_duration(data["duration"]),
            duration_seconds: data["duration"],
            cover: thumbnail,
            stream_url: data["url"],
            preview_url: data["url"],
            links: %{
              youtube: "https://www.youtube.com/watch?v=#{data["id"]}",
              youtube_music: "https://music.youtube.com/watch?v=#{data["id"]}"
            }
          }

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp get_best_thumbnail(nil), do: nil
  defp get_best_thumbnail([]), do: nil

  defp get_best_thumbnail(thumbnails) do
    Enum.find(thumbnails, fn t -> t["height"] && t["height"] >= 360 end)
    |> then(fn
      nil -> List.last(thumbnails)
      t -> t
    end)
    |> then(& &1["url"])
  end

  defp extract_formats(nil), do: []

  defp extract_formats(formats) do
    formats
    |> Enum.filter(fn f -> f["acodec"] && f["acodec"] != "none" end)
    |> Enum.map(fn f ->
      %{
        format_id: f["format_id"],
        ext: f["ext"],
        quality: f["quality"],
        abr: f["abr"],
        url: f["url"]
      }
    end)
  end

  defp track_from_ytdlp_data(data, fallback_url) when is_map(data) do
    webpage =
      data["webpage_url"] || data["original_url"] || data["url"] || fallback_url

    extractor =
      (data["extractor_key"] || data["extractor"] || "generic")
      |> to_string()
      |> String.downcase()

    raw_id = to_string(data["id"] || "")
    source = source_from_extractor(extractor, webpage)
    video_id = stable_track_id(source, raw_id, webpage)
    thumbnail = data["thumbnail"] || get_best_thumbnail(data["thumbnails"])

    links =
      %{
        "webpage_url" => webpage
      }
      |> maybe_put_link(source, webpage)

    %{
      video_id: video_id,
      title: data["title"],
      artist: data["uploader"] || data["channel"] || data["creator"] || data["artist"],
      duration: format_duration(data["duration"]),
      duration_seconds: data["duration"],
      cover: thumbnail,
      stream_url: data["url"],
      preview_url: data["url"],
      formats: extract_formats(data["formats"]),
      source: source,
      extractor: extractor,
      webpage_url: webpage,
      links: links
    }
  end

  defp stable_track_id("youtube", raw_id, _webpage) when raw_id != "", do: raw_id

  defp stable_track_id("soundcloud", raw_id, _webpage) when raw_id != "",
    do: "sc_" <> raw_id

  defp stable_track_id(_source, raw_id, webpage) when is_binary(webpage) and webpage != "" do
    hash =
      :crypto.hash(:sha256, webpage)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    if raw_id != "", do: "x_#{raw_id}_#{hash}", else: "x_#{hash}"
  end

  defp stable_track_id(_source, raw_id, _webpage) when raw_id != "", do: "x_#{raw_id}"
  defp stable_track_id(_, _, _), do: "x_unknown"

  defp source_from_extractor(extractor, webpage) do
    cond do
      String.contains?(extractor, "soundcloud") ->
        "soundcloud"

      String.contains?(extractor, "youtube") ->
        "youtube"

      is_binary(webpage) and String.contains?(webpage, "soundcloud.com") ->
        "soundcloud"

      is_binary(webpage) and
          (String.contains?(webpage, "youtube.com") or String.contains?(webpage, "youtu.be")) ->
        "youtube"

      String.contains?(extractor, "bandcamp") ->
        "bandcamp"

      String.contains?(extractor, "vimeo") ->
        "vimeo"

      true ->
        "web"
    end
  end

  defp maybe_put_link(links, "soundcloud", url), do: Map.put(links, "soundcloud", url)
  defp maybe_put_link(links, "youtube", url), do: Map.put(links, "youtube", url)
  defp maybe_put_link(links, _, _), do: links

  defp first_json_object(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> List.first()
    |> case do
      nil ->
        case Jason.decode(output) do
          {:ok, data} when is_map(data) -> {:ok, data}
          _ -> {:error, :no_json}
        end

      line ->
        Jason.decode(line)
    end
  end

  defp referer_for(url) when is_binary(url) do
    cond do
      String.contains?(url, "soundcloud.com") -> "https://soundcloud.com/"
      true -> "https://www.youtube.com/"
    end
  end

  defp normalize_url(input) when is_binary(input) do
    trimmed = String.trim(input)

    cond do
      String.starts_with?(trimmed, "http") ->
        trimmed

      String.starts_with?(trimmed, "sc_") ->
        trimmed

      String.length(trimmed) == 11 and Regex.match?(~r/^[A-Za-z0-9_-]{11}$/, trimmed) ->
        "https://www.youtube.com/watch?v=#{trimmed}"

      true ->
        trimmed
    end
  end

  defp format_duration(nil), do: "0:00"

  defp format_duration(seconds) when is_number(seconds) do
    seconds = round(seconds)
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    if hours > 0 do
      "#{hours}:#{String.pad_leading("#{minutes}", 2, "0")}:#{String.pad_leading("#{secs}", 2, "0")}"
    else
      "#{minutes}:#{String.pad_leading("#{secs}", 2, "0")}"
    end
  end

  defp format_duration(_), do: "0:00"

  @doc """
  Common anti-bot hardening args (UA rotation, referer, cookies when configured).
  """
  def hardening_args do
    base =
      [
        "--extractor-retries",
        "3",
        "--user-agent",
        random_user_agent(),
        "--referer",
        "https://www.youtube.com/",
        "--add-header",
        "Accept-Language:en-US,en;q=0.9"
      ] ++ player_client_args()

    case get_cookies_path() do
      nil -> base
      path -> base ++ ["--cookies", path]
    end
  end

  @default_player_clients "tv_simply,web_safari,mweb"

  @doc """
  Which YouTube player clients to ask, in order.
  """
  def player_client_args do
    clients =
      System.get_env("YTDLP_PLAYER_CLIENTS", @default_player_clients)
      |> to_string()
      |> String.trim()

    if clients == "" do
      []
    else
      ["--extractor-args", "youtube:player_client=#{clients}"]
    end
  end

  defp random_user_agent do
    agents = [
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15",
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    ]

    Enum.random(agents)
  end

  defp get_cookies_path do
    case System.get_env("YTDLP_COOKIES_CONTENT") do
      nil ->
        check_existing_paths()

      content ->
        path = "/tmp/cookies.txt"
        File.write!(path, content)
        path
    end
  end

  defp check_existing_paths do
    case System.get_env("YTDLP_COOKIES_PATH") do
      nil ->
        default_path = "/app/cookies.txt"
        if File.exists?(default_path), do: default_path, else: nil

      path ->
        if File.exists?(path), do: path, else: nil
    end
  end
end
