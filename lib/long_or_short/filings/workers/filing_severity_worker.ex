defmodule LongOrShort.Filings.Workers.FilingSeverityWorker do
  @moduledoc """
  Oban cron that promotes Tier-1-only `FilingAnalysis` rows to fully
  scored (LON-136, Phase 3a of the two-tier dilution epic).

  Background sweep for what was originally specced as an on-demand
  UI-mount trigger. LON-160 reviewed that pattern and pivoted:
  Tier 2 is currently deterministic + `$0` (`Filings.Scoring` is
  rule-based, never LLM), so there's no cost reason to defer scoring
  to user action — a 5-minute sweep keeps every Tier 1 row promoted
  within minutes of landing.

  Each promoted row broadcasts `:new_filing_analysis` on
  `\"filings:analyses\"` via `Filings.Events.broadcast_analysis_ready/1`
  (already wired into `score_severity/1` in LON-134). LON-162 adds
  the LiveView listeners that consume those broadcasts.

  ## Schedule

  Cron-driven, every 5 minutes (`*/5 * * * *`), queue
  `:filings_analysis` (concurrency 2 — but Cron plugin only enqueues
  one job per tick).

  ## Idempotency

  The `:pending_tier_2` query filters to `extraction_quality = :high
  AND dilution_severity IS NULL`. Once a row is scored, the next
  sweep doesn't see it.

  ## Failure handling

  Per-row `score_severity/1` errors are logged and counted via
  `BatchHelper`; the cycle never aborts on a single failure.

  ## Telemetry

  Emits `[:long_or_short, :filing_severity_worker, :complete]` with
  `%{ok, error, total}`. No cost telemetry — Tier 2 is `$0`, only
  rows-processed counts matter for observability.
  """

  use Oban.Worker, queue: :filings_analysis, max_attempts: 3
  require Logger

  alias LongOrShort.Filings
  alias LongOrShort.Workers.BatchHelper

  @batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    pending = find_pending(@batch_size)
    total = length(pending)

    if total == 0 do
      Logger.debug("FilingSeverityWorker: no pending Tier 2 rows")
      :ok
    else
      run_batch(pending, total)
    end
  end

  defp find_pending(limit) do
    case Filings.list_pending_tier_2_analyses(
           %{},
           page: [limit: limit],
           authorize?: false
         ) do
      {:ok, %Ash.Page.Keyset{results: results}} -> results
      _ -> []
    end
  end

  defp run_batch(rows, total) do
    Logger.info("FilingSeverityWorker: scoring #{total} pending Tier 2 rows")

    counts = BatchHelper.process_batch(rows, &score_one/1)

    Logger.info(
      "FilingSeverityWorker: complete — ok=#{counts.ok} error=#{counts.error}"
    )

    BatchHelper.emit_complete_telemetry(:filing_severity_worker, counts, total)
    :ok
  end

  defp score_one(analysis) do
    case Filings.score_severity(analysis) do
      {:ok, _scored} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "FilingSeverityWorker: score failed for analysis #{analysis.id} — " <>
            "#{inspect(reason)}"
        )

        :error
    end
  end
end
