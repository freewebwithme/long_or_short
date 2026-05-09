defmodule LongOrShort.Filings do
  @moduledoc """
  Filings domain — regulatory filings collected from external sources.

  Feeders (currently SEC EDGAR via `LongOrShort.Filings.Sources.SecEdgar`)
  ingest into this domain via `ingest_filing/2`. Full document bodies live
  in `LongOrShort.Filings.FilingRaw` (cold storage), populated by Stage 3a
  (LON-113) when AI extraction fetches the document text.
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
  end
end
