defmodule LongOrShort.Filings do
  @moduledoc """
  Filings domain — regulatory filings collected from external sources.

  Feeders (currently SEC EDGAR via `LongOrShort.Filings.Sources.SecEdgar`)
  ingest into this domain via `ingest_filing/2`. Full document bodies live
  in `LongOrShort.Filings.FilingRaw` (cold storage), populated by Stage 1b
  (LON-119). Dilution-risk verdicts produced by the AI pipeline live in
  `LongOrShort.Filings.FilingAnalysis` (LON-115, Stage 3c).

  Form 4 (insider transactions) takes a different path — see
  "Form 4: structured XML, no LLM" below.

  ## Single entry points for analysis

  Three public functions trigger the dilution pipeline, all delegating
  to `LongOrShort.Filings.Analyzer`:

    * `analyze_filing/1,2` — full pipeline (Tier 1 + Tier 2 in sequence).
      The orchestrator used by `FilingAnalysisWorker` today.
    * `extract_keywords/1,2` — Tier 1 only (LON-134). Cheap proactive
      pass: LLM extraction → persisted with `dilution_severity = nil`.
      Used by the universe-wide extractor (LON-135).
    * `score_severity/1,2` — Tier 2 only (LON-134). Reads the Tier 1
      row, runs scoring, fills in the severity verdict. Used by the
      on-demand `/analyze` + ticker-page triggers (LON-136).

  Callers (Oban workers, future on-demand UI) should always go through
  these domain functions rather than touching `Analyzer` directly —
  that keeps this module the single grep-able entry for filing
  operations.

  ## Form 4: structured XML, no LLM (LON-118)

  Form 4 (`:form4`) is the SEC's standard form for insider
  transaction reporting. Unlike S-1 / 8-K which are prose, Form 4
  is well-defined XML — `LongOrShort.Filings.Form4Parser` extracts
  the transactions directly and persists them to
  `LongOrShort.Filings.InsiderTransaction`. No LLM cost, no
  extraction quality variance.

  Cross-referencing those insider transactions against
  dilution-relevant filings (the "insider sold within N days of
  the latest dilution filing" signal) lives in
  `LongOrShort.Filings.InsiderCrossReference`, which is what
  feeds `:insider_selling_post_filing` in
  `LongOrShort.Tickers.get_dilution_profile/1`.
  """

  use Ash.Domain, otp_app: :long_or_short

  resources do
    resource LongOrShort.Filings.Filing do
      define :create_filing, action: :create
      define :ingest_filing, action: :ingest
      define :get_filing, action: :read, get_by: [:id]
      define :list_filings, action: :read
      define :list_filings_by_ticker, action: :by_ticker, args: [:ticker_id]
      define :list_recent_filings, action: :recent
      define :destroy_filing, action: :destroy
    end

    resource LongOrShort.Filings.FilingRaw do
      define :create_filing_raw, action: :create
      define :get_filing_raw, action: :read, get_by: [:filing_id]
      define :destroy_filing_raw, action: :destroy
    end

    resource LongOrShort.Filings.FilingAnalysis do
      define :create_filing_analysis, action: :create
      define :upsert_filing_analysis_tier_1, action: :upsert_tier_1
      define :update_filing_analysis_tier_2, action: :update_tier_2
      define :get_filing_analysis, action: :read, get_by: [:id]

      define :get_filing_analysis_by_filing,
        action: :get_by_filing,
        args: [:filing_id],
        get?: true,
        not_found_error?: false

      define :list_filing_analyses_by_ticker, action: :by_ticker, args: [:ticker_id]
      define :list_recent_filing_analyses, action: :recent
      define :destroy_filing_analysis, action: :destroy
    end

    resource LongOrShort.Filings.InsiderTransaction do
      define :create_insider_transaction, action: :create
      define :get_insider_transaction, action: :read, get_by: [:id]
      define :list_insider_transactions_by_ticker, action: :by_ticker, args: [:ticker_id]
      define :list_insider_transactions_by_filing, action: :by_filing, args: [:filing_id]
      define :destroy_insider_transaction, action: :destroy
    end
  end

  @doc """
  Run Tier 1 + Tier 2 (extraction → scoring → persistence) for a
  Filing and broadcast on `\"filings:analyses\"`. See
  `LongOrShort.Filings.Analyzer` for the full pipeline + error
  semantics.
  """
  defdelegate analyze_filing(filing_id), to: LongOrShort.Filings.Analyzer
  defdelegate analyze_filing(filing_id, opts), to: LongOrShort.Filings.Analyzer

  @doc """
  Tier 1 only — LLM extraction + persistence with `dilution_severity = nil`.
  See `LongOrShort.Filings.Analyzer.extract_keywords/2`.
  """
  defdelegate extract_keywords(filing_id), to: LongOrShort.Filings.Analyzer
  defdelegate extract_keywords(filing_id, opts), to: LongOrShort.Filings.Analyzer

  @doc """
  Tier 2 only — scoring of an existing Tier 1 row.
  See `LongOrShort.Filings.Analyzer.score_severity/2`.
  """
  defdelegate score_severity(filing_analysis_or_id), to: LongOrShort.Filings.Analyzer

  defdelegate score_severity(filing_analysis_or_id, opts),
    to: LongOrShort.Filings.Analyzer
end
