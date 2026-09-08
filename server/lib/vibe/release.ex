defmodule Vibe.Release do
  @app :vibe

  def migrate do
    load_app()
    prefer_migration_url()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    prefer_migration_url()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  # Migrations take DDL locks that transaction-pooled PgBouncer cannot hold.
  defp prefer_migration_url do
    case System.get_env("MIGRATION_DATABASE_URL") do
      url when is_binary(url) and url != "" ->
        config = Application.get_env(@app, Vibe.Repo, [])
        Application.put_env(@app, Vibe.Repo, Keyword.put(config, :url, url))

      _ ->
        :ok
    end
  end
end
