defmodule LongOrShort.Filings.Filing do
  @moduledoc """
  A regulatory filing scoped to a single ticker.

  Filings are ingested by `LongOrShort.Filings.Sources.*` feeders
  (currently SEC EDGAR, see LON-111). When a filing references multiple
  tickers — possible but rare for SEC forms — the feeder splits it into
  one row per ticker. This keeps per-ticker timeline queries trivial
  (`WHERE ticker_id = X`) and is consistent with `LongOrShort.News.Article`.

  ## Identity

  The `:ingest` action upserts on `[source, external_id, ticker_id]`. On
  conflict, mutable content fields (`filing_subtype`, `filer_cik`, `url`)
  are overwritten with the latest payload — feeders may refine subtype
  classification or correct a URL after first emission. Identity columns
  and timestamps (`filed_at`, `fetched_at`) are preserved so timeline
  ordering stays stable across re-ingests.

  ## Cold storage

  The full filing body is stored separately in `LongOrShort.Filings.FilingRaw`
  (table `filings_raw`) so 100KB+ S-1 documents never bloat hot-path queries
  on `filings`. `FilingRaw` is populated by Stage 3a (LON-113) when AI
  extraction fetches the document body.

  ## Pagination

  The `:recent` read action uses keyset pagination sorted by `id: :desc`.
  See `LongOrShort.News.Article` for the full rationale on why we sort by
  `:id` (uuid_v7) rather than the temporal column — Ash 3.x keyset cursors
  break on microsecond ties, which the SEC EDGAR poller can produce when
  parsing a batch of entries with identical `<updated>` timestamps.
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Filings,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "filings"
    repo LongOrShort.Repo

    # (ticker_id, filed_at) supports the hot-path "filings for ticker X, newest
    # first" query. ASC index — Postgres can scan B-trees backwards just as
    # cheaply, so no DESC fragment needed.
    custom_indexes do
      index [:ticker_id, :filed_at], name: "filings_ticker_id_filed_at_index"
    end

    references do
      reference :ticker, on_delete: :restrict, on_update: :update
    end
  end

  identities do
    identity :unique_source_external_ticker, [:source, :external_id, :ticker_id]
  end

  attributes do
    uuid_v7_primary_key :id

    create_timestamp :fetched_at
    update_timestamp :updated_at

    attribute :source, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:sec_edgar]
      description "Originating filings provider."
    end

    attribute :filing_type, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :s1,
                    :s1a,
                    :s3,
                    :s3a,
                    :_424b1,
                    :_424b2,
                    :_424b3,
                    :_424b4,
                    :_424b5,
                    :_8k,
                    :_13d,
                    :_13g,
                    :def14a,
                    :form4
                  ]

      description "SEC form type. Underscore prefix on numeric forms is required by Elixir atom syntax."
    end

    attribute :filing_subtype, :string do
      public? true
      description "Optional subtype refinement, e.g. \"8-K Item 3.02\" or \"8-K Item 1.01\"."
    end

    attribute :external_id, :string do
      allow_nil? false
      public? true
      description "Source-provided identifier — for SEC EDGAR this is the accession number."
    end

    attribute :filer_cik, :string do
      allow_nil? false
      public? true
      description "10-digit zero-padded SEC Central Index Key of the filer."
    end

    attribute :filed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "Filing timestamp from the source header (Atom <updated> for SEC EDGAR)."
    end

    attribute :url, :string do
      public? true
      description "Canonical document URL at the source."
    end
  end

  relationships do
    belongs_to :ticker, LongOrShort.Tickers.Ticker do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    has_one :filing_raw, LongOrShort.Filings.FilingRaw do
      public? true
      destination_attribute :filing_id
    end
  end

  actions do
    defaults [:read, :destroy]

    # Direct create — caller has already resolved the ticker. Tests and
    # internal call sites use this. Feeders should prefer :ingest.
    create :create do
      primary? true

      accept [
        :source,
        :filing_type,
        :filing_subtype,
        :external_id,
        :filer_cik,
        :filed_at,
        :url,
        :ticker_id
      ]
    end

    # Feeder-friendly upsert. Takes a :symbol argument and resolves it to
    # a Ticker (creating a minimal one if it doesn't exist yet). Idempotent
    # on (source, external_id, ticker_id).
    create :ingest do
      description """
      Upsert a filing from an external feeder. Accepts `symbol` and handles
      Ticker resolution internally.

      On conflict `(source, external_id, ticker_id)`, mutable content fields
      (`filing_subtype`, `filer_cik`, `url`) are overwritten. Identity
      columns, `filed_at`, and `fetched_at` are preserved so timeline
      ordering stays stable across re-ingests.
      """

      upsert? true
      upsert_identity :unique_source_external_ticker

      upsert_fields [:filing_subtype, :filer_cik, :url]

      accept [
        :source,
        :filing_type,
        :filing_subtype,
        :external_id,
        :filer_cik,
        :filed_at,
        :url
      ]

      argument :symbol, :string do
        allow_nil? false
        description "Ticker symbol. Ticker is created if it doesn't exist."
      end

      change manage_relationship(:symbol, :ticker,
               value_is_key: :symbol,
               on_lookup: :relate,
               on_no_match: {:create, :upsert_by_symbol},
               use_identities: [:unique_symbol]
             )
    end

    read :by_ticker do
      argument :ticker_id, :uuid, allow_nil?: false

      filter expr(ticker_id == ^arg(:ticker_id))

      prepare build(sort: [filed_at: :desc])
    end

    read :recent do
      pagination keyset?: true, required?: false, default_limit: 30

      # Sort by `id: :desc` rather than `filed_at: :desc`. See the
      # `LongOrShort.News.Article` "Pagination + sort design" docs for
      # the full rationale (Ash keyset cursors break on microsecond ties).
      prepare build(sort: [id: :desc])
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Policies — mirrors Article pattern.
  # See LON-15: SystemActor bypass is a MVP shortcut.
  # Filings have no trader-write surface; ingest is feeder-only.
  # ─────────────────────────────────────────────────────────────────────
  policies do
    bypass actor_attribute_equals(:system?, true) do
      authorize_if always()
    end

    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end
end
