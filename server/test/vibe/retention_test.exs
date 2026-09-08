defmodule Vibe.RetentionTest do
  use ExUnit.Case, async: false

  alias Vibe.Repo
  alias Vibe.Retention

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    previous = Application.get_env(:vibe, :background_jobs, true)
    Application.put_env(:vibe, :background_jobs, true)
    on_exit(fn -> Application.put_env(:vibe, :background_jobs, previous) end)
    :ok
  end

  test "run_once deletes expired audit rows and keeps the recent row" do
    old = DateTime.utc_now() |> DateTime.add(-366 * 86_400, :second) |> DateTime.truncate(:second)
    recent = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.query!("INSERT INTO audit_events (action, metadata, inserted_at) VALUES ($1, $2, $3), ($1, $2, $3)", ["expired", %{}, old])
    Repo.query!("INSERT INTO audit_events (action, metadata, inserted_at) VALUES ($1, $2, $3)", ["recent", %{}, recent])

    assert :ok = Retention.run_once()
    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM audit_events")
    assert %{rows: [["recent"]]} = Repo.query!("SELECT action FROM audit_events")
  end
end
