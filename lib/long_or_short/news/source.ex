defmodule LongOrShort.News.Source do
  @moduledoc """
  Behaviour shared by all news source GenServers (Benzinga, SEC,
  PR Newswire, the Dummy in dev, etc.).

  Each feeder is its own GenServer that owns the polling state and
  HTTP/API access to its source. The common pipeline logic — first-
  poll scheduling, fetch → parse → dedup → ingest → broadcast,
  exponential backoff on errors — lives in
  `LongOrShort.News.Sources.Pipeline` so it can be unit-tested
  independently of any real source.

  ## Required callbacks

  ### `fetch_news/1`

  Called from the polling loop to retrieve a batch of raw items from
  the source. The returned `new_state` is threaded back into the
  next poll, so a feeder can store cursors like `last_poll_at` here.

  Errors do not crash the GenServer — they go into exponential
  backoff via `Source.Backoff`. Use `{:error, reason, new_state}` to
  signal a recoverable failure.

  ### `parse_response/1`

  Converts a single raw item from `fetch_news/1` into a list of
  attribute maps suitable for `News.ingest_article/2`. Returning a
  list (rather than a single map) lets a single source article that
  mentions multiple tickers fan out into one Article per ticker —
  matching the per-ticker storage model the Article resource uses.

  Each returned attrs map must include at least:

      %{
        source: :benzinga,                 # atom in Article enum
        external_id: "abc-123",            # source's own id
        symbol: "BTBD",                    # uppercase ticker symbol
        title: "Headline...",
        published_at: ~U[2026-04-25 12:00:00.000000Z]
      }

  Optional fields: `:summary`, `:url`, `:raw_category`, `:sentiment`.

  ### `poll_interval_ms/0`

  Base polling interval in milliseconds, used after a successful
  fetch. Errors temporarily extend this via exponential backoff.
  """

  @callback fetch_news(state :: map()) ::
              {:ok, [raw_item :: map()], new_state :: map()}
              | {:error, reason :: term(), new_state :: map()}

  @callback parse_response(raw_item :: map()) ::
              {:ok, [article_attrs :: map()]}
              | {:error, reason :: term()}

  @callback poll_interval_ms() :: pos_integer()
end
