defmodule Vibe.Links do
  @moduledoc """
  Canonical Vibe **share links** — the one place that knows what a public link looks like.
  """

  alias Vibe.Accounts
  alias Vibe.Agents
  alias Vibe.Chat

  # The host that actually resolves these paths today.
  @default_share_base "https://api.vibegram.io"

  # Single-segment paths the web app (or infra) owns.
  @reserved_handles ~w[
    about admin agent agents api app assets blog bridge dashboard docs download
    fonts health help images j l login logout pricing privacy r register robots
    settings signup static support terms u uploads user users vibe well-known
    favicon.ico logo.png robots.txt sw.js manifest.json registerSW.js index.html
  ]

  @doc """
  Base URL every share link hangs off, without a trailing slash.
  """
  def share_base_url do
    case present(System.get_env("VIBE_SHARE_BASE_URL")) do
      nil -> @default_share_base
      value -> normalize_base(value)
    end
  end

  @doc false
  def default_share_base, do: @default_share_base

  @doc """
  Public link for a person or an agent handle: `https://<base>/<handle>`.
  """
  def handle_url(handle) do
    case normalize_handle(handle) do
      nil -> nil
      value -> "#{share_base_url()}/#{value}"
    end
  end

  def profile_url(user), do: handle_url(user)
  def agent_url(agent), do: handle_url(agent)

  @doc """
  Absolute URL for a room share link.
  """
  def room_url(nil), do: nil

  def room_url(link) when is_binary(link) do
    case String.trim(link) do
      "" ->
        nil

      "http" <> _ = absolute ->
        absolute

      "/r/" <> _ = path ->
        absolute(path)

      "/j/" <> _ = path ->
        absolute(path)

      slug ->
        absolute("/r/#{slug}")
    end
  end

  def room_url(_), do: nil

  @doc "Absolute URL for a path on the share host."
  def absolute("/" <> _ = path), do: share_base_url() <> path
  def absolute(path) when is_binary(path), do: share_base_url() <> "/" <> path
  def absolute(_), do: nil

  @doc """
  Human-facing form of a link — scheme stripped, so the UI shows
  `vibegram.io/newsroom` rather than `https://vibegram.io/newsroom`.
  """
  def display(nil), do: nil

  def display(url) when is_binary(url) do
    url
    |> String.replace(~r{^https?://}, "")
    |> String.replace_trailing("/", "")
    |> present()
  end

  @doc """
  Deep link that opens a resolved target straight in the app.
  """
  def deep_link(%{kind: :channel, slug: slug}) when is_binary(slug),
    do: "vibe://room-link?" <> URI.encode_query(%{"slug" => slug})

  def deep_link(%{kind: :channel, chat_id: chat_id}) when is_binary(chat_id),
    do: "vibe://chat?" <> URI.encode_query(%{"chatId" => chat_id})

  def deep_link(%{handle: handle, user_id: user_id}) when is_binary(handle) do
    query = %{"handle" => handle}
    query = if is_binary(user_id), do: Map.put(query, "userId", user_id), else: query
    "vibe://u?" <> URI.encode_query(query)
  end

  def deep_link(_), do: nil

  @doc "True when a single path segment belongs to the web app or infra, not to a user."
  def reserved_handle?(handle) do
    case handle do
      value when is_binary(value) -> String.downcase(String.trim(value)) in @reserved_handles
      _ -> false
    end
  end

  @doc false
  def reserved_handles, do: @reserved_handles

  @doc """
  Resolves one path segment to whatever it points at.
  """
  def resolve_handle(handle, opts \\ []) do
    normalized = normalize_handle(handle)

    cond do
      is_nil(normalized) -> {:error, :not_found}
      reserved_handle?(normalized) -> {:error, :reserved}
      true -> lookup_handle(normalized, opts)
    end
  end

  defp lookup_handle(handle, opts) do
    case Accounts.get_any_user_by_username(handle) do
      %{is_agent: true} = user -> agent_target(user, handle, opts)
      %{} = user -> {:ok, user_target(user, handle)}
      _ -> channel_target(handle)
    end
  end

  defp agent_target(user, handle, opts) do
    agent = Agents.get_agent_by_shadow_user(user.id)

    visible? =
      cond do
        is_nil(agent) -> false
        Keyword.get(opts, :include_unpublished, false) -> true
        agent.status == "published" -> true
        agent.owner_user_id == Keyword.get(opts, :viewer_user_id) -> true
        true -> false
      end

    if visible? do
      target = %{
        kind: :agent,
        handle: handle,
        title: present(agent.display_name) || present(user.name) || "@#{handle}",
        subtitle: "Vibe agent",
        description: present(agent.persona) || present(user.bio),
        avatar_url: present(agent.avatar_url) || present(user.profile_image),
        user_id: user.id,
        agent_id: agent.id,
        status: agent.status,
        chat_id: nil,
        slug: nil
      }

      {:ok, with_links(target)}
    else
      {:error, :not_found}
    end
  end

  defp user_target(user, handle) do
    avatar =
      if to_string(user.privacy_profile_photos || "everybody") == "everybody" do
        present(user.profile_image)
      end

    %{
      kind: :user,
      handle: handle,
      title: present(user.name) || "@#{handle}",
      subtitle: "on Vibe",
      description: nil,
      avatar_url: avatar,
      user_id: user.id,
      agent_id: nil,
      status: nil,
      chat_id: nil,
      slug: nil
    }
    |> with_links()
  end

  defp channel_target(handle) do
    case Chat.resolve_channel_link("/r/#{handle}") do
      {:ok, room} ->
        target = %{
          kind: :channel,
          handle: handle,
          title: room[:name] || "@#{handle}",
          subtitle: channel_subtitle(room),
          description: room[:description],
          avatar_url: room[:avatarUrl],
          user_id: nil,
          agent_id: nil,
          status: nil,
          chat_id: room[:chatId],
          slug: room[:publicSlug] || handle
        }

        {:ok, with_links(target)}

      _ ->
        {:error, :not_found}
    end
  end

  defp channel_subtitle(room) do
    case room[:subscriberCount] || room[:memberCount] do
      count when is_integer(count) and count == 1 -> "Channel · 1 subscriber"
      count when is_integer(count) and count > 1 -> "Channel · #{count} subscribers"
      _ -> "Channel"
    end
  end

  defp with_links(%{kind: :channel, slug: slug} = target) when is_binary(slug) do
    target
    |> Map.put(:url, absolute("/r/#{slug}"))
    |> Map.put(:deep_link, deep_link(target))
  end

  defp with_links(target) do
    target
    |> Map.put(:url, handle_url(target.handle))
    |> Map.put(:deep_link, deep_link(target))
  end

  @doc """
  JSON-safe view of a resolved target for API responses and tool results.
  """
  def target_payload(target) when is_map(target) do
    %{
      "kind" => to_string(target.kind),
      "handle" => target.handle,
      "title" => target.title,
      "subtitle" => target.subtitle,
      "description" => target.description,
      "avatar_url" => target.avatar_url,
      "user_id" => target.user_id,
      "agent_id" => target.agent_id,
      "chat_id" => target.chat_id,
      "public_slug" => target.slug,
      "link" => target.url,
      "link_display" => display(target.url),
      "deep_link" => target.deep_link
    }
  end

  @doc """
  Normalizes anything handle-shaped to a bare lowercase handle.
  """
  def normalize_handle(nil), do: nil

  def normalize_handle(value) when is_binary(value) do
    value
    |> String.trim()
    |> strip_link_prefix()
    |> String.trim_leading("@")
    |> String.trim("/")
    |> String.downcase()
    |> present()
  end

  def normalize_handle(%{agent_user: %{username: username}}), do: normalize_handle(username)
  def normalize_handle(%{username: username}), do: normalize_handle(username)
  def normalize_handle(%{"username" => username}), do: normalize_handle(username)
  def normalize_handle(_), do: nil

  defp strip_link_prefix(value) do
    case String.split(value, "://", parts: 2) do
      [_scheme, rest] -> rest |> String.split("/", parts: 2) |> List.last()
      _ -> value
    end
  end

  defp normalize_base(value) do
    trimmed = String.trim_trailing(String.trim(value), "/")

    if String.contains?(trimmed, "://") do
      trimmed
    else
      "https://" <> trimmed
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil
end
