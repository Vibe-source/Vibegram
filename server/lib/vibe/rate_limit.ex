defmodule Vibe.RateLimit do
  @moduledoc """
  Resolves the configured rate-limit backend and its optional Redix child spec.
  `VibeWeb.Plugs.RateLimiter` calls `Vibe.RateLimit.backend().hit/3`.
  """

  @doc "Backend module selected by RATE_LIMIT_BACKEND (default ets; valkey requires VALKEY_URL)."
  def backend do
    case System.get_env("RATE_LIMIT_BACKEND") do
      "valkey" -> Vibe.RateLimit.Valkey
      _ -> Vibe.RateLimit.ETS
    end
  end

  @doc "Redix child spec list for application.ex — empty (no-op) unless VALKEY_URL is set."
  def redix_child_specs do
    case System.get_env("VALKEY_URL") do
      url when is_binary(url) and url != "" -> [{Redix, {url, [name: Vibe.Redix]}}]
      _ -> []
    end
  end
end
