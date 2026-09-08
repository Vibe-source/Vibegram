defmodule VibeWeb.RoomLinkController do
  use VibeWeb, :controller

  def public(conn, %{"slug" => slug}) do
    redirect(conn, external: "vibe://room-link?#{URI.encode_query(%{"slug" => slug})}")
  end

  def private(conn, %{"token" => token}) do
    redirect(conn, external: "vibe://room-link?#{URI.encode_query(%{"token" => token})}")
  end
end
