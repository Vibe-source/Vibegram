defmodule Vibe.RateLimit.Backend do
  @moduledoc """
  Behaviour for a rate-limit counter backend. `hit/3` records one request against `key` and
  reports whether it is within `max` for the current `window_ms`.
  """

  @callback hit(key :: term(), max :: pos_integer(), window_ms :: pos_integer()) ::
              {:ok, remaining :: integer(), reset_at_ms :: integer()}
              | {:error, retry_after_ms :: integer(), reset_at_ms :: integer()}
end
