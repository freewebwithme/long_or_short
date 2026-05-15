defmodule LongOrShort.Filings.Workers.IngestHealthReporter do
  @moduledoc """
  Daily Oban Cron worker that surfaces Tier 1 ingest health (LON-161).

  Aggregates the last `@window_hours` (24h by default) across two
  ephemeral failure modes that don't show up in any single resource:

    * **CIK drops** — pulled from `Filings.IngestHealth`'s ETS counter,
      atomically read + reset on every cycle. Lost on app restart by
      design (see that module's docstring).
    * **Tier 1 rejections** — queried from `FilingAnalysis` rows whose
      `extraction_quality` is `:rejected`, grouped by `rejected_reason`
      (top-5 only — long tail is rarely actionable).

  Emits a single Logger summary line plus a
  `[:long_or_short, :ingest_health, :daily_summary]` telemetry event
  for any downstream dashboards. Health *gating* (e.g. paging on
  threshold breach) is intentionally out of scope here — LON-161
  only ships the visibility primitive.

  ## Ordering note

  Analysis stats are computed BEFORE the CIK-drop counter is drained.
  If the DB query raises, Oban retries; the counter is preserved so
  the retry doesn't under-report. The drain-then-process order would
  silently zero out drop data on transient DB failures.

  ## Schedule

  Daily at 06:00 UTC, registered via `Oban.Plugins.Cron`. Sits right
  after the 05:00 `FinnhubProfileSync` so any same-cycle FinnhubProfile
  errors are already settled in source state when this runs.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Ash.Query
  require Logger

  alias LongOrShort.Filings.{FilingAnalysis, IngestHealth}

  @window_hours 24

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    window_start =
      DateTime.utc_now()
      |> DateTime.add(-@window_hours * 3600, :second)

    # DB-side aggregation FIRST so a transient read failure doesn't
    # drain the ephemeral CIK drop counters.
    analysis_stats = analysis_stats(window_start)
    cik_drops = IngestHealth.read_and_reset_cik_drops()

    log_summary(analysis_stats, cik_drops)
    emit_telemetry(analysis_stats, cik_drops)

    :ok
  end

  # ── Analysis aggregation ───────────────────────────────────────

  defp analysis_stats(window_start) do
    # `type(..., :utc_datetime_usec)` preserves microseconds in the
    # bound parameter — without it, the DateTime binds as
    # `:utc_datetime` (second precision) and rows at the same second
    # boundary filter inconsistently.
    # See [[feedback-ash-datetime-usec-filter]].
    rows =
      FilingAnalysis
      |> Ash.Query.filter(analyzed_at >= type(^window_start, :utc_datetime_usec))
      |> Ash.Query.select([:extraction_quality, :rejected_reason])
      |> Ash.read!(authorize?: false)

    total = length(rows)
    by_quality = Enum.frequencies_by(rows, & &1.extraction_quality)

    top_rejected_reasons =
      rows
      |> Stream.filter(&(&1.extraction_quality == :rejected))
      # `rejected_reason` can be an atom, string, or `{:rate_limited, _}`
      # tuple — `inspect/1` gives a stable string key for grouping.
      |> Enum.frequencies_by(&inspect(&1.rejected_reason))
      |> Enum.sort_by(fn {_, count} -> -count end)
      |> Enum.take(5)

    rejection_rate_pct =
      case total do
        0 -> 0.0
        n -> Float.round(100.0 * Map.get(by_quality, :rejected, 0) / n, 1)
      end

    %{
      total: total,
      high: Map.get(by_quality, :high, 0),
      medium: Map.get(by_quality, :medium, 0),
      rejected: Map.get(by_quality, :rejected, 0),
      rejection_rate_pct: rejection_rate_pct,
      top_rejected_reasons: top_rejected_reasons
    }
  end

  # ── Logger summary ─────────────────────────────────────────────

  defp log_summary(stats, cik_drops) do
    Logger.info(
      "IngestHealthReporter (#{@window_hours}h) — " <>
        "analyses: total=#{stats.total} high=#{stats.high} " <>
        "medium=#{stats.medium} rejected=#{stats.rejected} " <>
        "rejection_rate=#{stats.rejection_rate_pct}% | " <>
        "cik_drops: news=#{cik_drops.news} filings=#{cik_drops.filings}"
    )

    if stats.top_rejected_reasons != [] do
      reasons_str =
        stats.top_rejected_reasons
        |> Enum.map_join(", ", fn {reason, count} -> "#{count}× #{reason}" end)

      Logger.info("IngestHealthReporter top rejected reasons: #{reasons_str}")
    end
  end

  # ── Telemetry ──────────────────────────────────────────────────

  defp emit_telemetry(stats, cik_drops) do
    :telemetry.execute(
      [:long_or_short, :ingest_health, :daily_summary],
      %{
        window_hours: @window_hours,
        analyses_total: stats.total,
        analyses_high: stats.high,
        analyses_medium: stats.medium,
        analyses_rejected: stats.rejected,
        rejection_rate_pct: stats.rejection_rate_pct,
        cik_drops_news: cik_drops.news,
        cik_drops_filings: cik_drops.filings
      },
      %{top_rejected_reasons: stats.top_rejected_reasons}
    )
  end
end
