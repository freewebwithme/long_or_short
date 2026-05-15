defmodule LongOrShort.Filings.Workers.FilingAnalysisWorker do
  @moduledoc """
  Oban cron worker that runs Tier 1 dilution extraction proactively
  across the small-cap universe (LON-135, Phase 2 of the two-tier
  dilution epic).

  Every 15 minutes, this worker finds Filings whose body has been
  fetched but no `FilingAnalysis` row exists yet, scoped to tickers
  in `LongOrShort.Tickers.small_cap_ticker_ids/0` (sourced from the
  LON-133 IWM universe), and calls `Filings.extract_keywords/1` on
  each. Each row lands with `extracted_keywords` populated and
  `dilution_severity = nil` — Tier 2 scoring is a separate on-demand
  path (LON-136).

  ## Why universe-scoped (LON-135 swap from watchlist-scoped)

  The pre-LON-135 design (LON-115) scoped this worker to the trader
  watchlist as a cost safeguard. That decision was reversed once we
  confirmed the actual workflow — small-cap momentum traders react
  to scanners + news in real time, so dilution data has to be ready
  for **every ticker that hits a card**, not just the few a trader
  has pre-watchlisted. LON-131 spec'd the two-tier split + this
  universe-wide ingest as the resolution. See [[project-lon131-split]].

  ## Cost ceiling

  Tier 1 invokes the cheap model only (Haiku 4.5 today; Qwen
  Singapore is the configured-but-disabled fallback). Combined with
  ~1,900 R2K tickers and ~hundreds of dilution-relevant filings/day,
  the target ceiling is **~$50/mo**. The acceptance criterion is
  observability — per-run + today's running total cost emit on every
  cron tick. A hard cap is intentionally not in this ticket (separate
  follow-up); the 200ms per-item pause acts as a soft rate-limit.

  ## Schedule

  Cron-driven, every 15 minutes (`*/15 * * * *`), queue
  `:filings_analysis` (concurrency 2 — but Cron plugin only enqueues
  one job per tick, so realistic parallelism is 1).

  ## Idempotency

  Two layers, same as before LON-135:

    * Query — `is_nil(filing_analysis)` skips Filings already analyzed.
    * Resource — `FilingAnalysis.:unique_filing_analysis` identity on
      `:filing_id`.

  Re-running Tier 1 on a row that has already been promoted by Tier 2
  is a no-op for the Tier 2 fields — `:upsert_tier_1.upsert_fields`
  doesn't include `:dilution_severity`, `:matched_rules`, or
  `:severity_reason` (see `FilingAnalysis` moduledoc).

  ## Failure handling

  Per-Filing errors are logged and counted but never abort the cycle.
  `Analyzer.extract_keywords/2` classifies errors itself — LLM
  failures produce a `:rejected` row (counted `:ok` since the analysis
  did run), transient errors return without persisting (counted
  `:skipped`).

  ## Telemetry

  Emits `[:long_or_short, :filing_analysis_worker, :complete]` once
  per cycle:

    * measurements — `%{ok, error, skipped, total, input_tokens,
      output_tokens, cost_cents, today_cost_cents}`
    * metadata — `%{tier: 1, model: <model id used in this batch | nil>}`

  `cost_cents` is this run's spend; `today_cost_cents` is the
  running total across all FilingAnalyses written today (UTC),
  letting dashboards alert on the monthly $50 ceiling without
  separate aggregation.
  """

  # Tier 1 batches can take 10-30 minutes under LON-163 retry-with-backoff
  # if Anthropic is throttling. The */15 cron keeps firing while a previous
  # batch is still running; without this unique constraint, queue
  # concurrency 2 lets two Tier 1 batches execute simultaneously and burst
  # into Anthropic's rate limit. The unique constraint dedupes any new
  # enqueue while a prior job is still :available / :scheduled / :executing
  # (LON-165). Effective Tier 1 concurrency = 1 regardless of queue setting.
  use Oban.Worker,
    queue: :filings_analysis,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  require Ash.Query
  require Logger

  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Filings
  alias LongOrShort.Filings.{Filing, FilingAnalysis}
  alias LongOrShort.Tickers

  @batch_size 20
  @default_per_item_pause_ms 200

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Tickers.small_cap_ticker_ids() do
      [] ->
        Logger.debug("FilingAnalysisWorker: small-cap universe is empty")
        :ok

      ticker_ids ->
        ticker_ids
        |> find_pending_filings(@batch_size)
        |> run_batch()
    end
  end

  # ── Query helpers ──────────────────────────────────────────────

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
    Logger.debug("FilingAnalysisWorker: no pending filings on universe tickers")
    :ok
  end

  defp run_batch(filings) do
    total = length(filings)
    Logger.info("FilingAnalysisWorker: extracting Tier 1 for #{total} pending filings")

    pause_ms =
      Application.get_env(
        :long_or_short,
        :filing_analysis_worker_pause_ms,
        @default_per_item_pause_ms
      )

    result =
      filings
      |> Enum.with_index()
      |> Enum.reduce(empty_accumulator(), fn {filing, idx}, acc ->
        if idx > 0 and pause_ms > 0, do: Process.sleep(pause_ms)
        extract_one(filing, acc)
      end)

    today_cost = today_cost_cents()

    Logger.info(
      "FilingAnalysisWorker: complete — ok=#{result.ok} error=#{result.error} " <>
        "skipped=#{result.skipped} run_cost_cents=#{result.cost_cents} " <>
        "today_cost_cents=#{today_cost}"
    )

    emit_telemetry(result, total, today_cost)
    :ok
  end

  defp empty_accumulator do
    %{
      ok: 0,
      error: 0,
      skipped: 0,
      input_tokens: 0,
      output_tokens: 0,
      cost_cents: 0,
      model: nil
    }
  end

  defp extract_one(filing, acc) do
    case Filings.extract_keywords(filing.id) do
      {:ok, analysis} ->
        %{input: in_tok, output: out_tok} = extract_tokens(analysis)
        cost = calc_cost_cents(analysis.model, in_tok, out_tok)

        %{
          acc
          | ok: acc.ok + 1,
            input_tokens: acc.input_tokens + in_tok,
            output_tokens: acc.output_tokens + out_tok,
            cost_cents: acc.cost_cents + cost,
            model: acc.model || analysis.model
        }

      {:error, reason}
      when reason in [:filing_raw_missing, :not_supported, :no_relevant_content] ->
        %{acc | skipped: acc.skipped + 1}

      {:error, reason} ->
        Logger.warning(
          "FilingAnalysisWorker: extract failed for #{filing.id} — #{inspect(reason)}"
        )

        %{acc | error: acc.error + 1}
    end
  end

  # ── Cost calculation ───────────────────────────────────────────

  defp extract_tokens(%{raw_response: %{"usage" => usage}}) when is_map(usage) do
    %{
      input: Map.get(usage, "input_tokens", 0) || 0,
      output: Map.get(usage, "output_tokens", 0) || 0
    }
  end

  defp extract_tokens(_), do: %{input: 0, output: 0}

  defp calc_cost_cents(model, input_tokens, output_tokens)
       when is_binary(model) and is_integer(input_tokens) and is_integer(output_tokens) do
    prices = Application.get_env(:long_or_short, :ai_model_prices, %{})

    case Map.get(prices, model) do
      %{input: in_per_m, output: out_per_m} ->
        div(input_tokens * in_per_m + output_tokens * out_per_m, 1_000_000)

      _ ->
        0
    end
  end

  defp calc_cost_cents(_, _, _), do: 0

  defp today_cost_cents do
    today_start =
      Date.utc_today()
      |> DateTime.new!(~T[00:00:00.000000])

    # `type(..., :utc_datetime_usec)` keeps microseconds in the bound
    # parameter; without it, the DateTime is bound as :utc_datetime
    # (second precision) and same-second rows get filtered inconsistently.
    # See [[feedback-ash-datetime-usec-filter]].
    FilingAnalysis
    |> Ash.Query.filter(analyzed_at >= type(^today_start, :utc_datetime_usec))
    |> Ash.Query.select([:model, :raw_response])
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn analysis, acc ->
      %{input: in_tok, output: out_tok} = extract_tokens(analysis)
      acc + calc_cost_cents(analysis.model, in_tok, out_tok)
    end)
  end

  # ── Telemetry ──────────────────────────────────────────────────

  defp emit_telemetry(result, total, today_cost) do
    :telemetry.execute(
      [:long_or_short, :filing_analysis_worker, :complete],
      %{
        ok: result.ok,
        error: result.error,
        skipped: result.skipped,
        total: total,
        input_tokens: result.input_tokens,
        output_tokens: result.output_tokens,
        cost_cents: result.cost_cents,
        today_cost_cents: today_cost
      },
      %{tier: 1, model: result.model}
    )
  end
end
