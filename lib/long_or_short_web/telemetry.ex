defmodule LongOrShortWeb.Telemetry do
  @moduledoc """
  Telemetry supervisor + metric registry for LongOrShort.

  Wires every `:telemetry.execute/3` emit site in the codebase into
  the LiveDashboard Metrics tab and (in dev) a `ConsoleReporter` for
  log-based observation. The `metrics: LongOrShortWeb.Telemetry` arg
  on `live_dashboard "/dashboard"` (router) calls `metrics/0` to build
  the dashboard's metric list.

  ## What lands here vs not

  Every event emitted under the `[:long_or_short, ...]` namespace
  should appear in `metrics/0` OR have a one-line comment explaining
  why it's skipped (boot-time-only counters, etc.). Adding a new emit
  site without a matching metric here means the data is invisible
  outside of `Logger.info` summary lines.

  ## Reporters

  Dev: `Telemetry.Metrics.ConsoleReporter` runs with a 60s period —
  noisier-than-helpful at the default 10s, useful as a backup view
  while LiveDashboard is open.

  Test / prod: no reporters mounted. Tests assert metric shape only
  (via `LongOrShortWeb.TelemetryTest`); production observability is
  deferred until LON-126 deploy lands a backend decision.
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children =
      [
        # Telemetry poller will execute the given period measurements
        # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
        {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      ] ++ maybe_console_reporter()

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ConsoleReporter is dev-only — too noisy in tests, and prod will
  # get a real metrics backend (Prometheus / OTLP) at LON-126 time.
  defp maybe_console_reporter do
    if Mix.env() == :dev do
      [{Telemetry.Metrics.ConsoleReporter, metrics: metrics(), reporter_options: [print_summary: false]}]
    else
      []
    end
  end

  def metrics do
    [
      # ── Phoenix metrics ──────────────────────────────────────────
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # ── Database metrics ─────────────────────────────────────────
      summary("long_or_short.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("long_or_short.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("long_or_short.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("long_or_short.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("long_or_short.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # ── VM metrics ───────────────────────────────────────────────
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # ── AI providers (per-call cost + token usage) ───────────────
      summary("long_or_short.ai.claude.call.input_tokens",
        description: "Anthropic Claude per-call input token count"
      ),
      summary("long_or_short.ai.claude.call.output_tokens",
        description: "Anthropic Claude per-call output token count"
      ),
      counter("long_or_short.ai.claude.call.input_tokens",
        description: "Anthropic Claude call count (any non-search)"
      ),
      summary("long_or_short.ai.claude.call_with_search.input_tokens"),
      summary("long_or_short.ai.claude.call_with_search.output_tokens"),
      sum("long_or_short.ai.claude.call_with_search.search_calls",
        description: "Total billed web_search tool calls across all generations"
      ),
      summary("long_or_short.ai.qwen.call.input_tokens"),
      summary("long_or_short.ai.qwen.call.output_tokens"),
      counter("long_or_short.ai.qwen.call.input_tokens",
        description: "Qwen call count"
      ),

      # ── Tier 1 dilution pipeline (LON-135) ───────────────────────
      counter("long_or_short.filing_analysis_worker.complete.ok",
        tags: [:model],
        description: "Tier 1 successful extractions per cycle"
      ),
      counter("long_or_short.filing_analysis_worker.complete.error",
        tags: [:model]
      ),
      counter("long_or_short.filing_analysis_worker.complete.skipped",
        tags: [:model]
      ),
      summary("long_or_short.filing_analysis_worker.complete.input_tokens",
        tags: [:model]
      ),
      summary("long_or_short.filing_analysis_worker.complete.output_tokens",
        tags: [:model]
      ),
      sum("long_or_short.filing_analysis_worker.complete.cost_cents",
        tags: [:model],
        description: "Running sum of this-run cost in cents"
      ),
      last_value("long_or_short.filing_analysis_worker.complete.today_cost_cents",
        description: "Today (UTC) running total across all Tier 1 rows"
      ),

      # ── Tier 2 + body fetcher + form 4 + backfill (BatchHelper) ──
      counter("long_or_short.filing_severity_worker.complete.ok"),
      counter("long_or_short.filing_severity_worker.complete.error"),
      counter("long_or_short.filing_body_fetcher.complete.ok"),
      counter("long_or_short.filing_body_fetcher.complete.error"),
      counter("long_or_short.form4_worker.complete.ok"),
      counter("long_or_short.form4_worker.complete.error"),
      counter("long_or_short.filing_analysis_backfill.complete.ok"),
      counter("long_or_short.filing_analysis_backfill.complete.error"),
      counter("long_or_short.filing_analysis_backfill.complete.skipped"),

      # ── Ingest health (LON-161) ──────────────────────────────────
      counter("long_or_short.filings.cik_drop.cik",
        tags: [:source],
        description: "Per-event count of unmapped CIK drops, by feeder"
      ),
      last_value("long_or_short.ingest_health.daily_summary.analyses_total"),
      last_value("long_or_short.ingest_health.daily_summary.analyses_high"),
      last_value("long_or_short.ingest_health.daily_summary.analyses_rejected"),
      last_value("long_or_short.ingest_health.daily_summary.rejection_rate_pct"),
      last_value("long_or_short.ingest_health.daily_summary.cik_drops_news"),
      last_value("long_or_short.ingest_health.daily_summary.cik_drops_filings"),

      # ── Profile / universe sync ──────────────────────────────────
      counter("long_or_short.finnhub_profile_sync.complete.ok",
        description: "Per-symbol Finnhub profile sync successes (LON-167)"
      ),
      counter("long_or_short.finnhub_profile_sync.complete.error"),
      last_value("long_or_short.finnhub_profile_sync.complete.total"),
      counter("long_or_short.small_cap_universe.sync_complete.ok",
        tags: [:source]
      ),
      counter("long_or_short.small_cap_universe.sync_complete.errors",
        tags: [:source]
      ),
      last_value("long_or_short.small_cap_universe.sync_complete.active_universe_size",
        tags: [:source]
      ),

      # ── FinnhubStream lifecycle (LON-67) ─────────────────────────
      counter("long_or_short.finnhub_stream.disconnected.attempt",
        tags: [:reason_bucket],
        description: "Disconnects bucketed by transient vs persistent"
      ),
      counter("long_or_short.finnhub_stream.reconnected.symbol_count",
        description: "Successful connect transitions (initial + reconnects)"
      ),
      summary("long_or_short.finnhub_stream.reconnected.symbol_count",
        description: "Distribution of symbol counts per successful connect"
      ),

      # ── Morning Brief generation ─────────────────────────────────
      counter("long_or_short.morning_brief.generated.duration_ms",
        tags: [:bucket]
      ),
      summary("long_or_short.morning_brief.generated.duration_ms",
        tags: [:bucket],
        unit: :millisecond
      ),
      summary("long_or_short.morning_brief.generated.input_tokens",
        tags: [:bucket]
      ),
      summary("long_or_short.morning_brief.generated.output_tokens",
        tags: [:bucket]
      ),
      sum("long_or_short.morning_brief.generated.search_calls",
        tags: [:bucket]
      ),
      counter("long_or_short.morning_brief.generation_failed.duration_ms",
        tags: [:bucket, :reason]
      )

      # ── Skipped emits ────────────────────────────────────────────
      # `[:long_or_short, :settings, :hydrate]` — boot-time only,
      # single emit per app start. Logger.info already covers it,
      # no value in a dashboard chart.
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
    ]
  end
end
