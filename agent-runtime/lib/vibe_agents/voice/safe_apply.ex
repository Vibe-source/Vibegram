defmodule VibeAgents.Voice.SafeApply do
  @moduledoc false

  # Calls mod.fun(args) only if it's loaded and exported.
  @spec call(module(), atom(), list(), term()) :: term()
  def call(mod, fun, args, fallback) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      try do
        apply(mod, fun, args)
      rescue
        _ -> fallback
      catch
        _, _ -> fallback
      end
    else
      fallback
    end
  end
end
