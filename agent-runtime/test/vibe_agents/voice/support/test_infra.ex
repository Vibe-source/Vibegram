defmodule VibeAgents.Voice.TestInfra do
  @moduledoc false
  # Idempotently boots the voice supervision primitives.

  def ensure_started! do
    ensure(VibeAgents.Voice.Sessions, [])
    ensure(Registry, keys: :unique, name: VibeAgents.Voice.Registry)
    ensure(DynamicSupervisor, name: VibeAgents.Voice.Supervisor, strategy: :one_for_one)
    :ok
  end

  defp ensure(mod, opts) do
    case mod.start_link(opts) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
