defmodule VibeWeb.LinkController do
  @moduledoc """
  Public share links (`https://vibegram.io/<handle>`) and their in-app resolution.
  """

  use VibeWeb, :controller

  alias Vibe.Links

  @app_id "BXY4DH6H7D.com.vibegram.app"

  def preview(conn, %{"handle" => handle} = params) do
    case Links.resolve_handle(handle) do
      {:ok, target} ->
        conn
        |> put_resp_header("content-type", "text/html; charset=utf-8")
        |> put_resp_header("cache-control", "public, max-age=60")
        |> send_resp(200, preview_html(target))

      _ ->
        VibeWeb.ApiController.index(conn, params)
    end
  end

  def resolve(conn, params) do
    viewer_id = conn.assigns.current_user.id
    raw = params["handle"] || params["link"] || params["url"] || params["value"] || ""

    case Links.resolve_handle(raw, viewer_user_id: viewer_id) do
      {:ok, target} ->
        json(conn, %{ok: true, target: Links.target_payload(target)})

      {:error, :reserved} ->
        conn
        |> put_status(:not_found)
        |> json(%{ok: false, error: "reserved_handle"})

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{ok: false, error: "not_found"})
    end
  end

  def aasa(conn, _params) do
    payload = %{
      "applinks" => %{
        "apps" => [],
        "details" => [
          %{
            "appIDs" => [@app_id],
            "components" => [
              %{"/" => "/r/*", "comment" => "public channel links"},
              %{"/" => "/j/*", "comment" => "private channel invites"},
              %{"/" => "/docs/*", "exclude" => true, "comment" => "web docs stay in the browser"},
              %{"/" => "/settings/*", "exclude" => true, "comment" => "web settings"},
              %{"/" => "/app", "exclude" => true, "comment" => "web app"},
              %{"/" => "/", "exclude" => true, "comment" => "marketing home"},
              %{"/" => "/*", "comment" => "@handle links"}
            ]
          }
        ]
      }
    }

    conn
    |> put_resp_header("content-type", "application/json")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, Jason.encode!(payload))
  end

  # ── preview page ──────────────────────────────────────────────────────────

  defp preview_html(target) do
    title = esc(target.title)
    handle = esc("@" <> target.handle)
    subtitle = esc(target.subtitle)
    description = target.description && esc(target.description)
    deep_link = esc(target.deep_link || "")
    url = esc(target.url || "")
    action = action_label(target.kind)
    og_description = target.description || default_description(target)

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>#{title} on Vibe</title>
    <meta name="theme-color" content="#0f0f0f" />
    <meta name="description" content="#{esc(og_description)}" />
    <meta property="og:site_name" content="Vibe" />
    <meta property="og:type" content="profile" />
    <meta property="og:title" content="#{title}" />
    <meta property="og:description" content="#{esc(og_description)}" />
    <meta property="og:url" content="#{url}" />
    #{og_image_tag(target)}
    <meta name="twitter:card" content="summary" />
    <link rel="canonical" href="#{url}" />
    <style>
      :root { color-scheme: dark light; }
      * { box-sizing: border-box; }
      body {
        margin: 0; min-height: 100vh; display: flex; align-items: center;
        justify-content: center; padding: 24px;
        background: #0f0f0f; color: #f5f5f7;
        font: 400 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      }
      .card {
        width: 100%; max-width: 380px; text-align: center;
        background: #1a1a1c; border: 1px solid rgba(255,255,255,0.08);
        border-radius: 28px; padding: 36px 28px 28px;
      }
      .avatar {
        width: 96px; height: 96px; border-radius: 50%; margin: 0 auto 20px;
        object-fit: cover; display: block; background: #2c2c2e;
      }
      .avatar-fallback {
        display: flex; align-items: center; justify-content: center;
        font-size: 38px; font-weight: 600; color: #8e8e93;
      }
      h1 { margin: 0 0 6px; font-size: 24px; font-weight: 700; letter-spacing: -0.02em; }
      .handle { margin: 0 0 2px; color: #0a84ff; font-size: 15px; font-weight: 500; }
      .subtitle { margin: 0; color: #8e8e93; font-size: 14px; }
      .bio { margin: 18px 0 0; color: #c7c7cc; font-size: 15px; }
      .open {
        display: block; margin: 26px 0 0; padding: 15px 20px;
        background: #0a84ff; color: #fff; border-radius: 16px;
        font-size: 16px; font-weight: 600; text-decoration: none;
      }
      .hint { margin: 14px 0 0; color: #636366; font-size: 13px; }
      .hint a { color: #8e8e93; }
      @media (prefers-color-scheme: light) {
        body { background: #f2f2f7; color: #1c1c1e; }
        .card { background: #fff; border-color: rgba(0,0,0,0.06); }
        .bio { color: #3a3a3c; }
      }
    </style>
    </head>
    <body>
      <main class="card">
        #{avatar_markup(target)}
        <h1>#{title}</h1>
        <p class="handle">#{handle}</p>
        <p class="subtitle">#{subtitle}</p>
        #{if description, do: ~s(<p class="bio">#{description}</p>), else: ""}
        <a class="open" id="open" href="#{deep_link}">#{action}</a>
        <p class="hint">Vibe not installed? <a href="/">Learn more</a></p>
      </main>
      <script>
        // Try the app straight away; the button stays for anyone the jump misses.
        (function () {
          var link = document.getElementById("open");
          if (!link || !link.getAttribute("href")) return;
          setTimeout(function () { window.location.href = link.getAttribute("href"); }, 60);
        })();
      </script>
    </body>
    </html>
    """
  end

  defp avatar_markup(%{avatar_url: url, title: title}) do
    case url do
      value when is_binary(value) and value != "" ->
        ~s(<img class="avatar" src="#{esc(value)}" alt="#{esc(title)}" />)

      _ ->
        ~s(<div class="avatar avatar-fallback">#{esc(initial(title))}</div>)
    end
  end

  defp og_image_tag(%{avatar_url: url}) when is_binary(url) and url != "",
    do: ~s(<meta property="og:image" content="#{esc(url)}" />)

  defp og_image_tag(_), do: ""

  defp action_label(:channel), do: "View Channel in Vibe"
  defp action_label(:agent), do: "Chat with this Agent"
  defp action_label(_), do: "Open in Vibe"

  defp default_description(%{kind: :agent, title: title}),
    do: "#{title} is a Vibe agent. Open the link to start chatting."

  defp default_description(%{kind: :channel, title: title}),
    do: "Join #{title} on Vibe."

  defp default_description(%{title: title}), do: "Message #{title} on Vibe."

  defp initial(title) do
    title
    |> to_string()
    |> String.trim_leading("@")
    |> String.first()
    |> case do
      nil -> "?"
      char -> String.upcase(char)
    end
  end

  defp esc(value), do: value |> to_string() |> Plug.HTML.html_escape()
end
