defmodule LongOrShort.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :long_or_short

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  # Run `priv/repo/seeds.exs` from inside a release (LON-127).
  #
  # Unlike `migrate/0` (which only needs the Repo via
  # `Ecto.Migrator.with_repo`), the seed calls Ash domain code
  # interfaces — so the full app supervision tree has to be up.
  # That would normally also start `LongOrShortWeb.Endpoint` and
  # try to bind port 4000, conflicting with the already-running
  # main app process on the same Machine. We override the endpoint
  # to `server: false` before starting the tree so the eval node
  # stays headless. The main process's `runtime.exs`-derived
  # `server: true` is unaffected.
  def seed do
    load_app()
    Application.put_env(:long_or_short, LongOrShortWeb.Endpoint, server: false)
    {:ok, _} = Application.ensure_all_started(@app)

    Code.eval_file(Path.join(:code.priv_dir(@app), "repo/seeds.exs"))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
