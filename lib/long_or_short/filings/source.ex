defmodule LongOrShort.Filings.Source do
  @moduledoc """
  Behaviour shared by all filings source GenServers (SEC EDGAR today,
  potentially SEDAR or other regulators in the future).

  Mirrors `LongOrShort.News.Source` in shape but covers regulatory
  filings (S-1, S-3, 424B*, 8-K, 13-D/G, DEF 14A, Form 4) rather
  than news articles. Filings carry different attributes than news
  articles — there is no "title/summary" headline; instead there is
  a typed filing record with a filer CIK and a filed_at timestamp.

  Common polling lifecycle (poll → fetch → parse → dedup → ingest →
  cursor update) lives in `LongOrShort.Filings.Sources.Pipeline`,
  matching the split used by the news pipeline.

  ## Required callbacks

  ### `fetch_filings/1`

  Called from the polling loop to retrieve a batch of raw items from
  the source. The returned `new_state` is threaded back into the
  next poll, so a feeder can store cursors here.

  Errors do not crash the GenServer — they go through exponential
  backoff via `LongOrShort.News.Sources.Backoff` (shared utility).
  Use `{:error, reason, new_state}` to signal a recoverable failure.

  ### `parse_response/1`

  Converts a single raw item from `fetch_filings/1` into a list of
  attribute maps suitable for the future `Filings.ingest_filing/1`
  code interface (delivered in Stage 2 / LON-112).

  Returning a list mirrors the news pipeline so a single source
  filing referencing multiple tickers can fan out to one row per
  ticker (per the per-ticker storage decision in the LON-106 epic).

  Each returned attrs map must include at least:

      %{
        source: :sec_edgar,                        # atom in Filing enum
        filing_type: :s1,                          # atom in Filing enum
        filing_subtype: "8-K Item 3.02",           # optional, string
        external_id: "0001234567-26-000123",       # SEC accession number
        symbol: "BTBD",                            # uppercase ticker symbol
        filer_cik: "0001234567",                   # zero-padded CIK
        filed_at: ~U[2026-05-08 12:00:00.000000Z],
        url: "https://www.sec.gov/..."
      }

  ### `source_name/0`

  Atom used as the primary key in `LongOrShort.Sources.SourceState`
  for cursor persistence across restarts. Must be present in the
  `SourceState.source` enum.

  ### `poll_interval_ms/0`

  Base polling interval in milliseconds, used after a successful
  fetch. Errors temporarily extend this via exponential backoff.
  """

  @callback fetch_filings(state :: map()) ::
              {:ok, [raw_item :: map()], new_state :: map()}
              | {:error, reason :: term(), new_state :: map()}

  @callback source_name() :: atom()

  @callback parse_response(raw_item :: map()) ::
              {:ok, [filing_attrs :: map()]}
              | {:error, reason :: term()}

  @callback poll_interval_ms() :: pos_integer()
end
