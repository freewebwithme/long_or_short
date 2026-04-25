defmodule LongOrShort.News.Dedup do
  @moduledoc """
  ETS-based fast dedup for the news ingestion pipeline.

  Sits between the feeder GenServers and `News.ingest_article/2` to
  drop articles already seen in the last 24 hours before they reach
  the Postgres upsert. The Article resource still has authoritative
  dedup via the `(source, external_id, ticker_id)` identity and
  `content_hash` — Dedup is a performance optimization, not a
  correctness mechanism.

  ## Key

  Articles are keyed by `(source, external_id, symbol)`, mirroring
  the Article DB identity. Symbol (string) is used here rather than
  ticker_id (uuid) because feeders work with symbols before ticker
  resolution happens inside the `:ingest` action.

  ## Concurrency

  All hot-path operations (`check_and_mark/3`, `seen?/3`) hit ETS
  directly without going through the GenServer. The GenServer's only
  responsibility is owning the table and running periodic cleanup.
  `check_and_mark/3` uses `:ets.insert_new/2` which is atomic, so
  concurrent feeders calling with the same key cannot both see `true`.

  ## TTL

  Entries expire 24 hours after insertion. A `:cleanup` message runs
  hourly to evict expired keys. TTL and cleanup interval are tunable
  via application config for testing.
  """

  use GenServer
  require Logger

  @table :news_seen
  @default_ttl_seconds 24 * 60 * 60
  @default_cleanup_interval :timer.hours(1)

  @doc """
  Starts the Dedup GenServer. Should be supervised by the
  application supervisor.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Atomically checks whether an article has been seen and marks it if
  not. Returns `true` if this is the first time seeing the key (and
  the caller should proceed to ingest), `false` if already seen.

  Uses `:ets.insert_new/2` so concurrent calls with the same key
  cannot both return `true`.
  """
  @spec check_and_mark(atom, String.t(), String.t()) :: boolean
  def check_and_mark(source, external_id, symbol)
      when is_atom(source) and is_binary(external_id) and is_binary(symbol) do
    key = build_key(source, external_id, symbol)
    :ets.insert_new(@table, {key, now()})
  end

  @doc """
  Returns `true` if the key has been marked, without modifying the
  table. Mostly useful for tests; production code should prefer
  `check_and_mark/3`.
  """
  @spec seen?(atom, String.t(), String.t()) :: boolean
  def seen?(source, external_id, symbol)
      when is_atom(source) and is_binary(external_id) and is_binary(symbol) do
    key = build_key(source, external_id, symbol)
    :ets.member(@table, key)
  end

  @doc """
  Removes all entries from the table. Test-only.
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  # ── GenServer callbacks ────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = now() - ttl_seconds() * 1_000
    deleted = :ets.select_delete(@table, cleanup_match_spec(cutoff))

    if deleted > 0 do
      Logger.debug("News.Dedup cleanup: removed #{deleted} expired entries")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  defp now, do: System.system_time(:millisecond)

  defp build_key(source, external_id, symbol) do
    :crypto.hash(:sha256, "#{source}|#{external_id}|#{symbol}")
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, cleanup_interval())
  end

  defp ttl_seconds do
    Application.get_env(:long_or_short, :news_dedup_ttl_seconds, @default_ttl_seconds)
  end

  defp cleanup_interval do
    Application.get_env(:long_or_short, :news_dedup_cleanup_interval, @default_cleanup_interval)
  end

  # match_spec: select rows where the timestamp ($1) is less than cutoff,
  # delete them. Returns the count of deleted rows.
  defp cleanup_match_spec(cutoff) do
    [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}]
  end
end
