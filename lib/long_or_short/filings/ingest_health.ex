defmodule LongOrShort.Filings.IngestHealth do
  @moduledoc """
  Ephemeral counters for Tier 1 ingest failure modes that do NOT
  produce a `FilingAnalysis` row — primarily CIK-resolution drops
  in both the news and filings SEC EDGAR feeders (LON-161).

  ## Design

  A single named ETS table holds per-source counters. The boot
  telemetry handler increments on `[:long_or_short, :filings, :cik_drop]`
  events; `IngestHealthReporter` reads + resets on the daily cron.

  Counters are intentionally process-local and ephemeral — restarts
  reset them to zero. The use case is "what dropped in the last 24h"
  observability, not auditable history. If long-term accounting is
  ever needed, persist the drops to a table instead.

  Rejected `FilingAnalysis` rows are NOT tracked here — they're
  already persisted with `extraction_quality = :rejected` and the
  reporter aggregates them directly from the database.

  ## Reason classification (deferred)

  Today the only drop reason known to the resolvers is `:unmapped_cik`.
  Distinguishing `:dup_cik` (multi-class share families like GOOG /
  GOOGL that intentionally share a parent CIK — see [[LON-132]]) from
  `:bootstrap_not_run` requires the CIK provenance LON-132 will
  persist. Once that ships, the metadata payload here gains a
  `:reason` key and `read_and_reset_cik_drops/0` returns a nested map.
  """

  @table :filings_ingest_health
  @cik_drop_event [:long_or_short, :filings, :cik_drop]
  @handler_id "filings-ingest-health-cik-drop-counter"

  @doc """
  The telemetry event name emitted by the SEC EDGAR resolvers on
  every CIK that fails to map to a local ticker. Exposed as a
  function so call sites don't typo the list literal.
  """
  @spec cik_drop_event_name() :: [atom()]
  def cik_drop_event_name, do: @cik_drop_event

  @doc """
  Create the ETS counter table. Idempotent — safe to call from
  `Application.start/2` and from per-test setup.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end

    :ok
  end

  @doc """
  Attach the boot telemetry handler that increments the per-source
  CIK drop counter. Detaches first so re-attaching in tests doesn't
  raise.
  """
  @spec attach_telemetry_handler() :: :ok | {:error, :already_exists}
  def attach_telemetry_handler do
    _ = :telemetry.detach(@handler_id)

    :telemetry.attach(
      @handler_id,
      @cik_drop_event,
      &__MODULE__.handle_cik_drop/4,
      nil
    )
  end

  @doc false
  def handle_cik_drop(_event, _measurements, %{source: source}, _config)
      when source in [:news, :filings] do
    :ets.update_counter(@table, {:cik_drop, source}, 1, {{:cik_drop, source}, 0})
    :ok
  end

  def handle_cik_drop(_event, _measurements, _metadata, _config), do: :ok

  @doc """
  Atomically removes and returns CIK drop counts per source.
  Subsequent increments recreate the keys at zero, so this is the
  primary interface for the daily reporter.
  """
  @spec read_and_reset_cik_drops() :: %{news: non_neg_integer(), filings: non_neg_integer()}
  def read_and_reset_cik_drops do
    %{
      news: take_counter({:cik_drop, :news}),
      filings: take_counter({:cik_drop, :filings})
    }
  end

  @doc """
  Non-destructive read of current CIK drop counts. Use this for
  ad-hoc debugging and tests that need to assert without disturbing
  the next reporter cycle.
  """
  @spec peek_cik_drops() :: %{news: non_neg_integer(), filings: non_neg_integer()}
  def peek_cik_drops do
    %{
      news: peek_counter({:cik_drop, :news}),
      filings: peek_counter({:cik_drop, :filings})
    }
  end

  defp take_counter(key) do
    case :ets.take(@table, key) do
      [{^key, val}] -> val
      [] -> 0
    end
  end

  defp peek_counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, val}] -> val
      [] -> 0
    end
  end
end
