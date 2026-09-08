defmodule Vibe.Repo.Migrations.AddAgentPreviousSecret do
  use Ecto.Migration

  @moduledoc """
  Rotating an agent secret used to be an instant cutover.
  """

  def change do
    alter table(:agents) do
      add :previous_secret_hash, :string
      add :previous_secret_expires_at, :utc_datetime
    end
  end
end
