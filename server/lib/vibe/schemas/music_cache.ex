defmodule Vibe.MusicCache do
  @moduledoc """
  Schema for caching music search results.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Vibe.Repo

  require Logger

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "music_cache" do
    field :query, :string           # Original search query (for reference)
    field :query_hash, :string      # Hash of original query
    field :source, :string, default: "youtube"
    field :video_id, :string        # Unique song identifier (YouTube video ID)
    field :title, :string           # Actual song title from source
    field :artist, :string          # Actual artist name from source
    field :album, :string
    field :duration, :string
    field :duration_seconds, :integer
    field :cover_url, :string
    field :stream_url, :string
    field :stream_expires_at, :utc_datetime
    field :preview_url, :string
    field :external_links, :map, default: %{}
    field :metadata, :map, default: %{}

    field :cached_file_path, :string  # Local/volume path to cached audio
    field :file_size_bytes, :integer  # File size for Content-Length
    field :cached_at, :utc_datetime   # When file was cached

    timestamps()
  end

  @doc """
  Look up cached tracks by video_id first (exact match),
  then by title+artist (fuzzy match for similar searches).
  """
  def get_cached(query) do
    now = DateTime.utc_now()
    normalized_query = normalize_for_search(query)

    from(m in __MODULE__,
      where: is_nil(m.stream_expires_at) or m.stream_expires_at > ^now,
      where: fragment("LOWER(?) LIKE ? OR LOWER(?) LIKE ?",
        m.title, ^"%#{normalized_query}%",
        m.artist, ^"%#{normalized_query}%"),
      order_by: [desc: m.inserted_at],
      limit: 5
    )
    |> Repo.all()
  end

  @doc """
  Get a specific track by video_id (identity lookup).
  """
  def get_by_video_id(video_id) when is_binary(video_id) do
    from(m in __MODULE__,
      where: m.video_id == ^video_id,
      order_by: [desc: m.updated_at],
      limit: 1
    )
    |> Repo.one()
  end

  def get_by_video_id(_), do: nil

  @doc """
  True when the ephemeral extractor `stream_url` is still considered fresh.
  Cached Supabase files (`cached_file_path`) are permanent and ignore this.
  """
  def stream_url_fresh?(%__MODULE__{stream_expires_at: nil}), do: true

  def stream_url_fresh?(%__MODULE__{stream_expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  def stream_url_fresh?(_), do: false

  @doc """
  Cache music search results.
  """
  def cache_results(query, tracks, source \\ "youtube") do
    query_hash = hash_query(query)
    expires_at = DateTime.utc_now() |> DateTime.add(6 * 60 * 60, :second)

    Enum.each(tracks, fn track ->
      video_id = track[:video_id] || track["video_id"]
      title = track[:title] || track["title"]
      artist = track[:artist] || track["artist"]

      if video_id do
        existing = get_by_video_id(video_id)

        attrs = %{
          query: query,
          query_hash: query_hash,
          source: source,
          video_id: video_id,
          title: title,
          artist: artist,
          album: track[:album] || track["album"],
          duration: track[:duration] || track["duration"],
          duration_seconds: coerce_seconds(track[:duration_seconds] || track["duration_seconds"]),
          cover_url: track[:cover] || track[:cover_url] || track["cover"],
          stream_url: track[:stream_url] || track[:preview_url] || track["stream_url"],
          stream_expires_at: expires_at,
          preview_url: track[:preview_url] || track["preview_url"],
          external_links: track[:links] || track["links"] || %{},
          metadata: %{}
        }

        result = if existing do
          existing
          |> changeset(attrs)
          |> Repo.update()
        else
          %__MODULE__{}
          |> changeset(attrs)
          |> Repo.insert()
        end

        case result do
          {:ok, _} ->
            Logger.info("[MusicCache] Cached: #{title} by #{artist} (#{video_id})")
          {:error, changeset} ->
            Logger.warning("[MusicCache] Failed to cache #{video_id}: #{inspect(changeset.errors)}")
        end
      end
    end)
  end

  @doc false
  def coerce_seconds(nil), do: nil
  def coerce_seconds(v) when is_integer(v), do: v
  def coerce_seconds(v) when is_float(v), do: round(v)

  def coerce_seconds(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> round(f)
      :error -> nil
    end
  end

  def coerce_seconds(_), do: nil

  @doc """
  Search cache by title and/or artist name.
  Returns tracks that match the actual song/artist names.
  """
  def search_by_name(title, artist \\ nil) do
    now = DateTime.utc_now()
    title_search = "%#{normalize_for_search(title)}%"

    query = from(m in __MODULE__,
      where: is_nil(m.stream_expires_at) or m.stream_expires_at > ^now,
      where: fragment("LOWER(?) LIKE ?", m.title, ^title_search),
      order_by: [desc: m.inserted_at],
      limit: 5
    )

    query = if artist do
      artist_search = "%#{normalize_for_search(artist)}%"
      from(m in query, where: fragment("LOWER(?) LIKE ?", m.artist, ^artist_search))
    else
      query
    end

    Repo.all(query)
  end

  @doc """
  Clean up expired cache entries (run periodically).
  """
  def cleanup_expired do
    now = DateTime.utc_now()
    cutoff = DateTime.utc_now() |> DateTime.add(-24 * 60 * 60, :second)

    {count, _} = from(m in __MODULE__,
      where: m.inserted_at < ^cutoff or
             (not is_nil(m.stream_expires_at) and m.stream_expires_at < ^now)
    )
    |> Repo.delete_all()

    Logger.info("[MusicCache] Cleaned up #{count} expired entries")
    count
  end

  defp changeset(struct, params) do
    struct
    |> cast(params, [
      :query, :query_hash, :source, :video_id, :title, :artist, :album,
      :duration, :duration_seconds, :cover_url, :stream_url, :stream_expires_at,
      :preview_url, :external_links, :metadata
    ])
    |> validate_required([:video_id, :title])
    |> unique_constraint(:video_id)
  end

  defp hash_query(query) do
    :crypto.hash(:sha256, String.downcase(String.trim(query)))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp normalize_for_search(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^\w\s]/u, "")  # Remove special chars
  end

  defp normalize_for_search(_), do: ""
end
