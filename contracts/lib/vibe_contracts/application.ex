defmodule VibeContracts.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([VibeContracts.NonceStore],
      strategy: :one_for_one,
      name: VibeContracts.Supervisor
    )
  end
end
