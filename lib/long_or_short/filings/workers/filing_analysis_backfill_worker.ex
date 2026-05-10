defmodule LongOrShort.Filings.Workers.FilingAnalysisBackfillWorker do
  @moduledoc """
  Oban worker that backfills `FilingAnalysis` for a ticker just added
  to a trader's watchlist (LON-115, Stage 3c).

  Enqueued from `LongOrShort.Tickers.WatchlistItem`'s `:add` action via
  an `after_action` change. When a trader adds a ticker to their
  watchlist, this worker analyzes that ticker's recent dilution-relevant
  filings so the dilution-profile UI is populated immediately rather
  than waiting up to 15 minutes for the next watchlist cron sweep.

  ## Args

      %{"ticker_id" => uuid, "lookback_days" => 90}

  `:lookback_days` defaults to 90 if absent. Stage 6's profile UI
  shows a 90-day window of dilution events; matching that here means
  every UI row has a backing analysis from the moment the ticker
  appears.

  ## Uniqueness

  Multiple traders adding the same ticker would otherwise enqueue
  duplicate backfill jobs. `unique:` on `[:args, :worker]` collapses
  those: only one backfill runs per ticker until that job completes.
  Once it lands, the cron worker (LON-115) keeps the analyses fresh.

  ## Queue + concurrency

  Shares the `:filings_analysis` queue (concurrency 2) with the cron
  worker. A backfill running while the cron sweeps is fine — they
  both call `Filings.analyze_filing/1`, which is idempotent at the
  resource level.

  ## Skip / error semantics

  Identical to the cron worker — see
  `LongOrShort.Filings.Workers.FilingAnalysisWorker`. The Analyzer
  classifies the outcome; this worker just counts and logs.

  ## Telemetry

  Emits `[:long_or_short, :filing_analysis_backfill, :complete]` per
  job with `%{ok: count, error: count, skipped: count, total: count,
  ticker_id: uuid, lookback_days: integer}`.
  """

  use Oban.Worker,
    queue: :filings_analysis,
    max_attempts: 3,
    unique: [fields: [:args, :worker], keys: [:ticker_id]]

  require Ash.Query
  require Logger

  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Filings
  alias LongOrShort.Filings.Filing

  @default_lookback_days 90

  @doc """
  Build a job for the given ticker. Use this from the WatchlistItem
  `:add` after_action change.
  """
  @spec new_job(Ash.UUID.t(), keyword()) :: Oban.Job.changeset()
  def new_job(ticker_id, opts \\ []) when is_binary(ticker_id) do
    lookback = Keyword.get(opts, :lookback_days, @default_lookback_days)

    new(%{"ticker_id" => ticker_id, "lookback_days" => lookback})
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    ticker_id = Map.fetch!(args, "ticker_id")
    lookback_days = Map.get(args, "lookback_days", @default_lookback_days)

    ticker_id
    |> find_pending_filings(lookback_days)
    |> run_batch(ticker_id, lookback_days)
  end

  # ── Query ──────────────────────────────────────────────────────

  defp find_pending_filings(ticker_id, lookback_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -lookback_days * 24 * 3600, :second)

    Filing
    |> Ash.Query.filter(
      ticker_id == ^ticker_id and
        filed_at >= ^cutoff and
        not is_nil(filing_raw) and
        is_nil(filing_analysis)
    )
    |> Ash.Query.sort(filed_at: :asc)
    |> Ash.read!(actor: SystemActor.new())
  end

  # ── Batch execution ────────────────────────────────────────────

  defp run_batch([], ticker_id, lookback_days) do
    Logger.debug(
      "FilingAnalysisBackfillWorker: nothing to backfill for ticker " <>
        "#{ticker_id} (#{lookback_days}d)"
    )

    :ok
  end

  defp run_batch(filings, ticker_id, lookback_days) do
    total = length(filings)

    Logger.info(
      "FilingAnalysisBackfillWorker: backfilling #{total} filings for ticker " <>
        "#{ticker_id} (#{lookback_days}d)"
    )

    {ok_count, err_count, skip_count} =
      Enum.reduce(filings, {0, 0, 0}, fn filing, {ok, err, skip} ->
        case Filings.analyze_filing(filing.id) do
          {:ok, _analysis} ->
            {ok + 1, err, skip}

          {:error, reason}
          when reason in [:filing_raw_missing, :not_supported, :no_relevant_content] ->
            {ok, err, skip + 1}

          {:error, reason} ->
            Logger.warning(
              "FilingAnalysisBackfillWorker: analyze failed for #{filing.id} — " <>
                inspect(reason)
            )

            {ok, err + 1, skip}
        end
      end)

    Logger.info(
      "FilingAnalysisBackfillWorker: complete — #{ok_count} ok, " <>
        "#{err_count} failed, #{skip_count} skipped"
    )

    :telemetry.execute(
      [:long_or_short, :filing_analysis_backfill, :complete],
      %{ok: ok_count, error: err_count, skipped: skip_count, total: total},
      %{ticker_id: ticker_id, lookback_days: lookback_days}
    )

    :ok
  end
end
