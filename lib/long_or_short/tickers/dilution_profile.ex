defmodule LongOrShort.Tickers.DilutionProfile do
  @moduledoc """
  Per-ticker dilution profile aggregator — LON-116, Stage 4.

  Walks `FilingAnalysis` rows for a ticker and produces a single
  ticker-scoped picture of dilution overhang for downstream consumers:

    * **Stage 5** (LON-117) — `NewsAnalyzer` injects this profile into
      its LLM prompt so news verdicts become dilution-aware.
    * **Stage 6** — `/dilution/:ticker` UI renders this directly as a
      summary card.

  ## Hybrid model: window vs lifecycle

  Most filing types are aggregated on a **rolling window**
  (`:dilution_profile_window_days`, default 180; see `config/config.exs`).
  Anything older drops out — stale info is worse than no info.

  ATMs are the lone exception and get **full lifecycle tracking** via
  `LongOrShort.Filings.AtmLifecycle`, regardless of window. The
  rationale lives in the AtmLifecycle moduledoc; in one line: a
  200-day-old ATM with 12M shares unsold today is the exact scenario
  small-cap momentum traders need to be warned about, and a window
  alone would lose it.

  ## Output shape

  Always returns a map with **every top-level key present**, using
  `nil` / `[]` / `:none` / `:insufficient` for "no data". This lets
  the Stage 5 prompt template do straight key access without
  per-field `Map.get/3` defaults.

      %{
        ticker_id: <uuid>,
        overall_severity: :critical | :high | :medium | :low | :none,
        overall_severity_reason: "ATM > 50% float (12M / 22M shares)" | nil,
        active_atm: %{remaining_shares: …, …} | nil,
        pending_s1: %{deal_size_usd: …, …} | nil,
        warrant_overhang: %{exercisable_shares: …, …} | nil,
        recent_reverse_split: %{ratio: "1:10", …} | nil,
        insider_selling_post_filing: false,        # Stage 9 stub
        flags: [atom()],
        last_filing_at: DateTime.t() | nil,
        data_completeness: :high | :partial | :insufficient
      }

  ## `data_completeness` semantics

  This field is the contract with Stage 5's prompt injection logic:

    * `:high` — active ATM resolved AND at least one in-window
      FilingAnalysis. Profile is trustworthy.
    * `:partial` — in-window data exists but no active ATM was
      resolved. Stage 5 can use the profile but should soften any
      "no ATM overhang" claim.
    * `:insufficient` — no in-window FilingAnalysis rows at all.
      Stage 5 should explicitly prompt: "no dilution data
      available — do not assume clean status." Silently absent
      dilution data is the trader's worst failure mode.

  ## Phase 1 intentional gaps

    * **`warrant_overhang` does not filter by strike < current price**
      (spec asks for it). Doing so would couple this module to
      `Ticker.last_price` and Decimal arithmetic, while
      over-reporting warrant overhang is the safer failure mode for
      a risk-warning system than under-reporting it. Calibration is
      LON-121.
    * **`:large_overhang` flag not computed.** Needs
      `ticker.float_shares`. Stage 5/6 can derive it from raw
      `remaining_shares` + `float_shares` directly.
    * **`:insider_selling_post_filing` populated by LON-118**, the
      Stage 9 Form 4 cross-reference. Computed live via
      `LongOrShort.Filings.InsiderCrossReference.insider_selling_post_dilution?/2`
      — `true` when an insider's open-market sale falls within
      `:insider_post_filing_window_days` (default 30) of the
      latest dilution-relevant filing.

  ## Evolution roadmap

  This module ships intentionally minimal. The LON-106 v2 spec's
  **incremental learning** approach decides what gets refined and
  when — each entry below names the *trigger* ("what signal tells
  us it's time?") rather than committing to a schedule. Don't add
  any of these speculatively; wait for the signal.

    * **Other filing types graduate from window-only to full
      lifecycle** when a trader hits a missed dilution case
      attributable to window staleness. Most likely candidates, in
      expected order: S-3 shelf (track `registered → supplement`
      chain), warrants (track `issued → exercised`), convertibles
      (track `issuance → conversion`). Each becomes its own
      `LongOrShort.Filings.XxxLifecycle` module mirroring
      `AtmLifecycle`'s shape, and this aggregator gains another
      `Xxx_lifecycle.resolve/2` call alongside the existing ATM one.

    * **`warrant_overhang` gains a strike < current_price filter**
      under LON-121's calibration program — most likely trigger is
      outcome tracking showing we over-report risk from deeply
      out-of-the-money warrants. Adds a dependency on
      `Ticker.last_price` (decide: load here, or take an
      `:as_of_price` opt for testability).

    * **Float-aware derived flags** (`:large_overhang`,
      `:dilution_over_float_threshold`, …) land here once multiple
      consumers (Stage 5 prompt, Stage 6 UI, future alerts) start
      duplicating the same `remaining_shares / float_shares`
      arithmetic. Until then, keep the raw numbers in the output
      and let each consumer interpret.

    * **`data_completeness` gains finer grading** when `:partial` is
      too coarse for downstream prompts to act on. Likely splits:
      `:stale` (latest filing > 90d), `:missing_type` (no S-3
      history despite catalysts implying one should exist),
      `:rejected_dominant` (too many `extraction_quality: :rejected`
      rows for the ticker to trust the rest).

    * **Caching** — ETS+TTL invalidated on `FilingAnalysis` upsert
      events. Trigger: profiling shows aggregation > 100ms on hot
      tickers, *or* per-request invocation grows past tens per
      second (Stage 5 NewsAnalyzer calling this on every article
      analysis is the most likely volume driver).

    * **`:insider_selling_post_filing` already wired** via LON-118's
      `InsiderCrossReference`. Future calibration may refine which
      filing types count as "dilution-relevant" (currently
      everything except `:form4`) and the 30d window.

    * **Per-ticker window override** when traders need a different
      cadence per sector (e.g. biotech ~360d window catches more
      relevant catalysts; fast-moving small-caps ~90d cuts stale
      noise). Probably a column on `Ticker` or `TradingProfile`
      rather than per-call opt — keeps the get/2 surface simple.

  Calibration of *severity rules themselves* (thresholds, severity
  assignments, rule combos) lives in the separate LON-121 program —
  not this module. This aggregator stays a pure consumer of whatever
  `dilution_severity` the rules engine produces.

  ## Performance

  No caching in Phase 1. One ticker's FilingAnalysis count is small
  (<100 typical, the order of "how many SEC filings has this ticker
  had over its lifetime that matter for dilution"); the read is a
  single indexed query (`(ticker_id, dilution_severity)` composite
  on `filing_analyses`) plus an in-memory `Enum.filter` for the
  window. If profiling shows hotspots later, ETS+TTL invalidated on
  `FilingAnalysis` upsert is the natural next step.
  """

  require Ash.Query

  alias LongOrShort.Filings.AtmLifecycle
  alias LongOrShort.Filings.FilingAnalysis
  alias LongOrShort.Filings.InsiderCrossReference

  # Lowest → highest. Used to rank `dilution_severity` for the
  # `overall_severity` computation. `:none` is the floor — rows
  # with `:none` are skipped by the filter, but kept in the order
  # list as documentation.
  @severity_order [:none, :low, :medium, :high, :critical]

  @type pending_s1 :: %{
          deal_size_usd: Decimal.t() | nil,
          filed_at: DateTime.t(),
          source_filing_id: String.t()
        }

  @type warrant_overhang :: %{
          exercisable_shares: integer(),
          avg_strike: Decimal.t() | nil,
          source_filing_ids: [String.t()]
        }

  @type reverse_split :: %{
          ratio: String.t() | nil,
          executed_at: DateTime.t(),
          source_filing_id: String.t()
        }

  @type t :: %{
          ticker_id: Ash.UUID.t(),
          overall_severity: atom(),
          overall_severity_reason: String.t() | nil,
          active_atm: AtmLifecycle.result() | nil,
          pending_s1: pending_s1() | nil,
          warrant_overhang: warrant_overhang() | nil,
          recent_reverse_split: reverse_split() | nil,
          insider_selling_post_filing: boolean(),
          flags: [atom()],
          last_filing_at: DateTime.t() | nil,
          data_completeness: :high | :partial | :insufficient
        }

  @doc """
  Build the dilution profile for `ticker_id`. Always returns a map —
  see the moduledoc for the full shape and `data_completeness`
  semantics.

  Options:

    * `:as_of` — `DateTime.t()`; reference time for the window
      cutoff and ATM dormancy. Defaults to `DateTime.utc_now/0`.
      Test-only override.
  """
  @spec get(Ash.UUID.t(), keyword()) :: t()
  def get(ticker_id, opts \\ []) do
    as_of = Keyword.get(opts, :as_of, DateTime.utc_now())
    window_days = Application.get_env(:long_or_short, :dilution_profile_window_days, 180)
    cutoff = DateTime.add(as_of, -window_days * 86_400, :second)

    in_window = load_analyses_in_window(ticker_id, cutoff)
    active_atm = AtmLifecycle.resolve(ticker_id, as_of: as_of)
    max_row = max_severity_row(in_window)

    %{
      ticker_id: ticker_id,
      overall_severity: severity_of(max_row),
      overall_severity_reason: reason_of(max_row),
      active_atm: active_atm,
      pending_s1: pending_s1(in_window),
      warrant_overhang: warrant_overhang(in_window),
      recent_reverse_split: recent_reverse_split(in_window),
      insider_selling_post_filing:
        InsiderCrossReference.insider_selling_post_dilution?(ticker_id, as_of: as_of),
      flags: aggregate_flags(in_window),
      last_filing_at: last_filing_at(in_window),
      data_completeness: data_completeness(in_window, active_atm)
    }
  end

  # ── Loading ──────────────────────────────────────────────────────

  defp load_analyses_in_window(ticker_id, cutoff) do
    FilingAnalysis
    |> Ash.Query.for_read(:by_ticker, %{ticker_id: ticker_id})
    |> Ash.Query.load(:filing)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(fn a -> DateTime.compare(a.filing.filed_at, cutoff) != :lt end)
  end

  # ── Severity ─────────────────────────────────────────────────────

  defp max_severity_row(analyses) do
    analyses
    |> Enum.filter(&(&1.dilution_severity != :none))
    |> Enum.max_by(
      fn a ->
        {severity_rank(a.dilution_severity),
         DateTime.to_unix(a.analyzed_at, :microsecond)}
      end,
      fn -> nil end
    )
  end

  defp severity_rank(severity), do: Enum.find_index(@severity_order, &(&1 == severity)) || 0
  defp severity_of(nil), do: :none
  defp severity_of(row), do: row.dilution_severity
  defp reason_of(nil), do: nil
  defp reason_of(row), do: row.severity_reason

  # ── pending_s1 — most recent S-1/S-1A within window ──────────────

  defp pending_s1(analyses) do
    analyses
    |> Enum.filter(fn a ->
      a.dilution_type == :s1_offering and a.filing.filing_type in [:s1, :s1a]
    end)
    |> Enum.max_by(&DateTime.to_unix(&1.filing.filed_at, :microsecond), fn -> nil end)
    |> case do
      nil ->
        nil

      row ->
        %{
          deal_size_usd: row.deal_size_usd,
          filed_at: row.filing.filed_at,
          source_filing_id: row.filing_id
        }
    end
  end

  # ── warrant_overhang — sum of warrant share counts within window ─

  defp warrant_overhang(analyses) do
    warrants =
      Enum.filter(analyses, fn a ->
        a.dilution_type == :warrant_exercise and is_integer(a.share_count)
      end)

    case warrants do
      [] ->
        nil

      list ->
        %{
          exercisable_shares: list |> Enum.map(& &1.share_count) |> Enum.sum(),
          avg_strike: average_strike(list),
          source_filing_ids: Enum.map(list, & &1.filing_id)
        }
    end
  end

  defp average_strike(rows) do
    strikes = rows |> Enum.map(& &1.warrant_strike) |> Enum.reject(&is_nil/1)

    case strikes do
      [] ->
        nil

      list ->
        sum = Enum.reduce(list, Decimal.new(0), fn s, acc -> Decimal.add(acc, s) end)
        Decimal.div(sum, Decimal.new(length(list)))
    end
  end

  # ── recent_reverse_split — most recent within window ─────────────

  defp recent_reverse_split(analyses) do
    analyses
    |> Enum.filter(&(&1.dilution_type == :reverse_split))
    |> Enum.max_by(&DateTime.to_unix(&1.filing.filed_at, :microsecond), fn -> nil end)
    |> case do
      nil ->
        nil

      row ->
        %{
          ratio: row.reverse_split_ratio,
          executed_at: row.filing.filed_at,
          source_filing_id: row.filing_id
        }
    end
  end

  # ── flags — per-row flags merged, no Phase 1 derivations ─────────

  defp aggregate_flags(analyses) do
    analyses
    |> Enum.flat_map(&(&1.flags || []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ── last_filing_at ───────────────────────────────────────────────

  defp last_filing_at([]), do: nil

  defp last_filing_at(analyses),
    do: analyses |> Enum.map(& &1.filing.filed_at) |> Enum.max(DateTime)

  # ── data_completeness ────────────────────────────────────────────

  defp data_completeness([], _active_atm), do: :insufficient
  defp data_completeness(_analyses, nil), do: :partial
  defp data_completeness(_analyses, _active_atm), do: :high
end
