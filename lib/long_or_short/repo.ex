defmodule LongOrShort.Repo do
  use AshPostgres.Repo,
    otp_app: :long_or_short

  @impl true
  def installed_extensions do
    # Add extensions here, and the migration generator will install them.
    ["ash-functions", "citext", AshMoney.AshPostgresExtension]
  end

  # Don't open unnecessary transactions
  # will default to `false` in 4.0
  @impl true
  def prefer_transaction? do
    false
  end

  @impl true
  def min_pg_version do
    %Version{major: 18, minor: 1, patch: 0}
  end

  # Force session TimeZone = UTC on every Postgres connection (LON-154).
  #
  # The Postgres server's default TimeZone is `America/New_York`. All our
  # timestamp columns are bare `timestamp without time zone` (Ecto's
  # default), but Ash/Ecto treat their values as `:utc_datetime_usec`.
  # When a query compares a bare column against a `timestamptz` parameter
  # (e.g. `WHERE published_at >= ^utc_since_arg`), Postgres silently
  # converts the bare column using the session TimeZone — shifting every
  # comparison by 4 hours in EDT, 5 hours in EST.
  #
  # `News.list_morning_brief`'s `:since` filter was the surface that made
  # this visible: tab clicks returned articles published hours before the
  # advertised window. Setting session TZ to UTC makes the bare columns
  # interpret consistently with their stored UTC values, so filters work
  # as intended without a 30+ column migration.
  @impl true
  def init(_type, config) do
    {:ok, Keyword.put_new(config, :parameters, [{"timezone", "UTC"}])}
  end
end
