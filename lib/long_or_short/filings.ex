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

  ## Single entry point for analysis

  `analyze_filing/1,2` is the public surface for triggering the
  extraction → scoring → persistence pipeline. It delegates to
  `LongOrShort.Filings.Analyzer`, which orchestrates Stages 3a + 3b
  and writes a `FilingAnalysis` row. Callers (Oban workers, future
  manual-trigger UI) should always go through this domain function
  rather than touching `Analyzer` directly — that keeps the domain
  module the single grep-able entry for filing operations.

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
      define :upsert_filing_analysis, action: :upsert
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
  Run extraction → scoring → persistence for a Filing and broadcast on
  `\"filings:analyses\"`. See `LongOrShort.Filings.Analyzer` for the
  full pipeline + error semantics.
  """
  defdelegate analyze_filing(filing_id), to: LongOrShort.Filings.Analyzer
  defdelegate analyze_filing(filing_id, opts), to: LongOrShort.Filings.Analyzer
end
