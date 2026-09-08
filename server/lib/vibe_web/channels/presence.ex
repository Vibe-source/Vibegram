defmodule VibeWeb.Presence do
  @moduledoc """
  Provides presence tracking to channels and processes.
  """
  use Phoenix.Presence,
    otp_app: :vibe,
    pubsub_server: Vibe.PubSub
end
