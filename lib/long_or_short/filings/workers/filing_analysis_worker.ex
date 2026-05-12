defmodule LongOrShort.Filings.Workers.FilingAnalysisWorker do
  @moduledoc """
  Oban cron worker that analyzes new dilution-relevant filings for
  watchlist tickers (LON-115, Stage 3c).

  Closes the loop between Stage 1b's body fetch (LON-119) and the
  `Filings.Analyzer` orchestrator: every 15 minutes, this worker
  finds Filings that have a body persisted but no analysis yet, scoped
  to tickers that are on at least one trader's watchlist, and runs
  `Filings.analyze_filing/1` on each.

  ## Why watchlist-scoped (not global auto)

  Pure auto-analyze of every dilution-relevant filing was rejected
  during LON-115 planning. SEC EDGAR emits dozens to hundreds of
  dilution-relevant filings per market day across all small-caps, and
  analyzing all of them would burn LLM cost on tickers no trader is
  watching. Scoping to the watchlist makes the cost ceiling
  predictable: it scales with explicit trader interest, not with the
  small-cap universe size.

  Non-watchlist tickers go through a manual trigger path (the
  `Filings.analyze_filing/1` code interface, used by the future
  dilution-profile UI's "Analyze" button).

  ## Schedule

  Cron-driven, every 15 minutes (`*/15 * * * *`). Pairs with the
  hourly-at-:15 body fetcher (LON-119) — the body lands first, the
  analyzer worker picks it up the next quarter-hour at the latest.

  ## Idempotency

  Two layers, mirroring the body fetcher:

    * Query — `is_nil(filing_analysis)` skips Filings that have already
      been analyzed (whether `:high` or `:rejected`), so re-running
      is cheap.
    * Resource — `FilingAnalysis.:unique_filing_analysis` identity on
      `:filing_id` enforces at most one row per Filing.

  Manual re-trigger via `Filings.analyze_filing/1` will overwrite the
  existing row through the upsert action; the worker itself never
  re-analyzes a Filing that already has a row.

  ## Failure handling

  Per-Filing analysis errors are logged and counted but never abort
  the cycle. The Analyzer already classifies errors — LLM failures
  produce a `:rejected` row (so we don't retry forever), transient
  errors return without persisting (so the next cycle picks them up).

  ## Telemetry

  Emits `[:long_or_short, :filing_analysis_worker, :complete]` once
  per cycle with `%{ok: count, error: count, skipped: count,
  total: count}`. `:skipped` covers the Analyzer's transient/
  out-of-scope return values (`:filing_raw_missing`, `:not_supported`,
  `:no_relevant_content`).
  """

  use Oban.Worker, queue: :filings_analysis, max_attempts: 3

  require Ash.Query
  require Logger

  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Filings
  alias LongOrShort.Filings.Filing
  alias LongOrShort.Tickers.WatchlistItem
  alias LongOrShort.Workers.BatchHelper

  @batch_size 20

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case watchlist_ticker_ids() do
      [] ->
        Logger.debug("FilingAnalysisWorker: no tickers on any watchlist")
        :ok

      ticker_ids ->
        ticker_ids
        |> find_pending_filings(@batch_size)
        |> run_batch()
    end
  end

  # ── Query helpers ──────────────────────────────────────────────

  defp watchlist_ticker_ids do
    WatchlistItem
    |> Ash.Query.select([:ticker_id])
    |> Ash.read!(actor: SystemActor.new())
    |> Enum.map(& &1.ticker_id)
    |> Enum.uniq()
  end

  defp find_pending_filings(ticker_ids, limit) do
    Filing
    |> Ash.Query.filter(
      ticker_id in ^ticker_ids and
        not is_nil(filing_raw) and
        is_nil(filing_analysis)
    )
    |> Ash.Query.sort(filed_at: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read!(actor: SystemActor.new())
  end

  # ── Batch execution ────────────────────────────────────────────

  defp run_batch([]) do
    Logger.debug("FilingAnalysisWorker: no pending filings on watchlist tickers")
    :ok
  end

  defp run_batch(filings) do
    total = length(filings)
    Logger.info("FilingAnalysisWorker: analyzing #{total} pending filings")

    counts =
      BatchHelper.process_batch(filings, &analyze_one/1,
        initial: %{ok: 0, error: 0, skipped: 0}
      )

    Logger.info(
      "FilingAnalysisWorker: complete — #{counts.ok} ok, #{counts.error} failed, " <>
        "#{counts.skipped} skipped"
    )

    BatchHelper.emit_complete_telemetry(:filing_analysis_worker, counts, total)
    :ok
  end

  defp analyze_one(filing) do
    case Filings.analyze_filing(filing.id) do
      {:ok, _analysis} ->
        :ok

      {:error, reason}
      when reason in [:filing_raw_missing, :not_supported, :no_relevant_content] ->
        :skip

      {:error, reason} ->
        Logger.warning(
          "FilingAnalysisWorker: analyze failed for #{filing.id} — #{inspect(reason)}"
        )

        :error
    end
  end
end
