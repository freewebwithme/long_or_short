defmodule LongOrShort.Filings.InsiderTransaction do
  @moduledoc """
  A single insider transaction extracted from a SEC Form 4 filing —
  LON-118, Stage 9 of the LON-106 dilution-aware analysis epic.

  One row per `<nonDerivativeTransaction>` in the Form 4 XML.
  Multiple transactions per filing are common — an executive
  selling across multiple price levels on the same day shows up as
  separate XML rows and so as separate rows here.

  ## Why a separate resource, not columns on `Filing`

  Form 4 has a 1:N relationship from filing → transactions, and we
  want the per-transaction row queryable (sum shares sold by date,
  filter by transaction code, etc.). Inlining as a JSON column on
  `Filing` would make those queries scan-based; a dedicated table
  with a `(ticker_id, transaction_date)` index serves
  `LongOrShort.Filings.InsiderCrossReference`'s "did this ticker
  have an open-market insider sale in the last N days?" query
  directly.

  ## No identity (intentional)

  Same `(filer, date, transaction_code)` triple can legitimately
  appear multiple times in one Form 4 — an officer selling across
  several price levels on the same day reports each level as its
  own `<nonDerivativeTransaction>` row. An identity on those four
  fields would dedupe legitimate rows.

  Idempotency is enforced at the worker layer instead:
  `LongOrShort.Filings.Workers.Form4Worker` wraps each filing's
  parse-and-insert in a DB transaction, so a filing either has
  zero rows or its full set. The worker's "find unprocessed
  filings" query then filters with
  `WHERE NOT EXISTS (SELECT 1 FROM insider_transactions WHERE filing_id = ?)`
  to avoid reprocessing — same pattern
  `FilingAnalysisWorker` uses for `FilingAnalysis`.

  ## Indexes

    * FK `:ticker_id` (auto from `belongs_to`).
    * FK `:filing_id` (auto from `belongs_to`) — drives the worker's
      `NOT EXISTS` query.
    * Composite `(ticker_id, transaction_date)` — drives
      `InsiderCrossReference`'s post-dilution window query.

  ## Policies

  Mirrors `Filing` / `FilingAnalysis`: SystemActor bypass for the
  worker; admin bypass; authenticated traders can read but not
  write. Writes happen exclusively via `Form4Worker` running as
  SystemActor — no trader-write surface.
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Filings,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "insider_transactions"
    repo LongOrShort.Repo

    references do
      reference :filing, on_delete: :restrict, on_update: :update
      reference :ticker, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      # Hot path: "give me this ticker's open-market sales since
      # date D" — the cross-reference flag query.
      # ASC index — Postgres scans both directions cheaply.
      index [:ticker_id, :transaction_date],
        name: "insider_transactions_ticker_id_transaction_date_index"
    end
  end

  attributes do
    uuid_v7_primary_key :id

    create_timestamp :inserted_at
    update_timestamp :updated_at

    attribute :filer_name, :string do
      public? true

      description """
      Reporting owner name as extracted from `<rptOwnerName>` —
      typically `Last, First` format. Nullable because some Form 4
      filings omit a usable owner name (corporate filers, etc.)
      and we'd rather store the transaction than reject it.
      """
    end

    attribute :filer_role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:officer, :director, :ten_percent_owner, :other]

      description """
      Reporting owner role collapsed by precedence
      `officer > director > ten_percent_owner > other`.
      See `Form4Parser` moduledoc for the rationale — a CEO sale
      is a stronger signal than a board director sale than a
      10%-owner sale.
      """
    end

    attribute :transaction_code, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :open_market_sale,
                    :open_market_purchase,
                    :exercise,
                    :gift,
                    :tax_withholding,
                    :other
                  ]

      description """
      SEC single-letter transaction code mapped to a semantic atom.
      `:open_market_sale` is the only code that drives the Phase 1
      dilution cross-reference flag — the rest are persisted for
      audit + future severity rules but don't change the
      `:insider_selling_post_filing` outcome today.
      """
    end

    attribute :share_count, :integer do
      public? true
      description "Shares involved in this transaction. Nullable when XML field is missing."
    end

    attribute :price, :decimal do
      public? true
      description "Per-share price when reported (always nil for `:gift`, sometimes nil for other codes)."
    end

    attribute :transaction_date, :date do
      allow_nil? false
      public? true

      description """
      Transaction execution date from `<transactionDate>`. Not the
      filing date — Form 4 must be filed within 2 business days of
      transaction, so these can differ by up to 2 days.
      """
    end
  end

  relationships do
    belongs_to :filing, LongOrShort.Filings.Filing do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :ticker, LongOrShort.Tickers.Ticker do
      allow_nil? false
      attribute_writable? true
      public? true

      description """
      Denormalized from `filing.ticker_id` so the
      `(ticker_id, transaction_date)` index can serve
      `InsiderCrossReference`'s ticker-scoped queries without a
      join. Same pattern as `FilingAnalysis.ticker_id`.
      """
    end
  end

  @fields [
    :filing_id,
    :ticker_id,
    :filer_name,
    :filer_role,
    :transaction_code,
    :share_count,
    :price,
    :transaction_date
  ]

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept @fields
    end

    read :by_ticker do
      description """
      All insider transactions for a ticker, newest first.
      Optional `:since` arg narrows to "transactions on or after
      this date" — `InsiderCrossReference`'s primary usage pattern
      to bound the post-dilution window.

      Optional `:transaction_code` filter — used by future
      severity rules that want e.g. "open-market sales only".
      """

      argument :ticker_id, :uuid, allow_nil?: false
      argument :since, :date, allow_nil?: true
      argument :transaction_code, :atom, allow_nil?: true

      filter expr(
               ticker_id == ^arg(:ticker_id) and
                 (is_nil(^arg(:since)) or transaction_date >= ^arg(:since)) and
                 (is_nil(^arg(:transaction_code)) or
                    transaction_code == ^arg(:transaction_code))
             )

      prepare build(sort: [transaction_date: :desc])
    end

    read :by_filing do
      description "All InsiderTransactions extracted from a single Form 4."
      argument :filing_id, :uuid, allow_nil?: false
      filter expr(filing_id == ^arg(:filing_id))
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Policies — mirrors `Filing` / `FilingAnalysis`.
  # SystemActor + admin bypass; trader read-only; no write surface
  # for traders (writes go through `Form4Worker` as SystemActor).
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
