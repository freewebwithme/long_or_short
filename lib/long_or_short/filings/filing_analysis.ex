defmodule LongOrShort.Filings.FilingAnalysis do
  @moduledoc """
  Persisted dilution-risk verdict for a single SEC filing — output of
  `LongOrShort.Filings.Analyzer` (LON-115, Stage 3c). One row per filing.

  ## Pipeline placement

  Stage 3a (`Filings.Extractor`, LON-113) pulls dilution facts from the
  filing body via LLM. Stage 3b (`Filings.Scoring` + `SeverityRules`,
  LON-114) turns those facts into a severity verdict. Stage 3c
  (this resource + `Filings.Analyzer`) persists the union and broadcasts
  on `\"filings:analyses\"` so downstream alerts (Stage 7) can react.

  ## Two-tier write lifecycle (LON-134)

  A row reaches its final state in **two separable writes**, so the
  cheap proactive phase and the expensive on-demand phase can run on
  different cadences (LON-131 epic):

    * **Tier 1 — `:upsert_tier_1`** (cheap, proactive). The LLM
      extraction pass. Persists `:extracted_keywords` (raw validated
      jsonb), the projected fact columns (`:dilution_type`,
      `:deal_size_usd`, etc.), and `:extraction_quality`. **Leaves
      `:dilution_severity` `nil`** — scoring hasn't run. Phase 2
      (LON-135) is what eventually drives this across the entire
      small-cap universe.

    * **Tier 2 — `:update_tier_2`** (on-demand). Reads the Tier 1
      keywords, runs `Filings.Scoring` against `SeverityRules`, and
      fills in `:dilution_severity`, `:matched_rules`,
      `:severity_reason`. May also downgrade `:extraction_quality` to
      `:rejected` when scoring-side validation catches a problem the
      extractor missed (filer CIK mismatch, implausible numbers).
      Phase 3 (LON-136) is what hooks this up to `/analyze` + ticker
      pages.

  Phase 0 of the refactor (this ticket, LON-134) is
  **behavior-preserving** — `FilingAnalysisWorker` still goes through
  `Analyzer.analyze_filing/2`, which calls both tiers in sequence.
  The proactive / on-demand split is wired up in LON-135 + LON-136.

  ## Field categories

    - **Extraction facts** — what the LLM pulled out of the filing
      (`:dilution_type`, deal sizing, ATM/shelf state, warrant terms,
      convertible flags, reverse-split proxy hints). Stored verbatim
      from `Extractor`'s validated output.
    - **Severity verdict** — what `Scoring.score/2` decided
      (`:dilution_severity`, `:matched_rules`, `:severity_reason`).
      Severity is **never** asked of the LLM — it is deterministic
      output of the rule engine.
    - **Quality + rejection** — `:extraction_quality` is
      `:high | :medium | :rejected`. Validation rejection records
      `:rejected_reason`. `:medium` is reserved for the LON-121
      calibration program (not produced by the current Scoring).
    - **Flags** — `:flags` is an atom array reserved for cross-cutting
      signals (e.g. \"insider sold within 5d of this filing\" — Stage 9).
      Phase 1 leaves it `[]`; the boolean attributes
      (`:has_anti_dilution_clause` etc.) carry the same information
      until Stage 9 promotes them to flags.
    - **LLM provenance** — `:provider`, `:model`, `:raw_response` —
      every persisted analysis is auditable back to the exact LLM
      response that produced it. Cost tracking shares this surface
      with `NewsAnalysis` (see LON-35 epic).

  ## Identity + lifecycle

  `:unique_filing_analysis` on `[:filing_id]` — re-running the analyzer
  on a Filing replaces the existing row via the `:upsert` action and
  advances `:analyzed_at`. We do **not** keep a history table of past
  runs; mirror's `NewsAnalysis`'s explicit decision (LON-78). If a
  future ticket needs run history, it should land it as a sibling
  `filing_analysis_runs` resource rather than retrofitting this one.

  ## Indexes

    - FK index on `:ticker_id` (auto from `belongs_to`).
    - Composite `(ticker_id, dilution_severity)` for the hot-path
      \"show me all critical-or-high FilingAnalyses for ticker X\"
      query that Stage 4 (LON-116) and the Stage 6 dilution profile
      UI will drive.

  ## Policies

  Mirrors `Filing` / `FilingRaw`: SystemActor bypass for the analyzer
  workers; admin bypass; authenticated traders can read but not write.
  Writes happen exclusively via `Filings.Analyzer` running as
  SystemActor — no trader-write surface, even for the manual trigger
  path (which calls the analyzer, which writes as system).
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Filings,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "filing_analyses"
    repo LongOrShort.Repo

    references do
      reference :filing, on_delete: :restrict, on_update: :update
      reference :ticker, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      # Hot path: "show critical/high dilution risks for ticker X". Stage 4
      # (LON-116) aggregates by ticker; Stage 6's UI filters by severity.
      # ASC index — Postgres scans B-trees backwards just as cheaply.
      index [:ticker_id, :dilution_severity],
        name: "filing_analyses_ticker_id_dilution_severity_index"
    end
  end

  identities do
    identity :unique_filing_analysis, [:filing_id]
  end

  attributes do
    uuid_v7_primary_key :id

    create_timestamp :analyzed_at
    update_timestamp :updated_at

    # ── Extraction facts (from Stage 3a Extractor) ────────────────
    attribute :dilution_type, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :atm,
                    :s1_offering,
                    :s3_shelf,
                    :pipe,
                    :warrant_exercise,
                    :convertible_conversion,
                    :reverse_split,
                    :none
                  ]

      description "Kind of dilution event the filing represents."
    end

    attribute :deal_size_usd, :decimal do
      public? true
      description "Total raised / authorized in USD when stated."
    end

    attribute :share_count, :integer do
      public? true
      description "Shares offered or covered by the filing when stated."
    end

    attribute :pricing_method, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:fixed, :market_minus_pct, :vwap_based, :unknown]
      description "How the offering price is set."
    end

    attribute :pricing_discount_pct, :decimal do
      public? true
      description "Discount to market for `:market_minus_pct` deals."
    end

    attribute :warrant_strike, :decimal do
      public? true
      description "Warrant exercise price when warrants are attached."
    end

    attribute :warrant_term_years, :integer do
      public? true
      description "Warrant exercise window in years."
    end

    attribute :atm_remaining_shares, :integer do
      public? true
      description "Shares remaining unsold under an ATM facility."
    end

    attribute :atm_total_authorized_shares, :integer do
      public? true
      description "Total shares authorized under the ATM at inception."
    end

    attribute :shelf_total_authorized_usd, :decimal do
      public? true
      description "Total dollars authorized under an S-3 shelf at inception."
    end

    attribute :shelf_remaining_usd, :decimal do
      public? true
      description "Dollars remaining unused under the shelf."
    end

    attribute :convertible_conversion_price, :decimal do
      public? true
      description "Conversion price for convertible notes / preferred."
    end

    attribute :has_anti_dilution_clause, :boolean do
      public? true
      default false
      description "Whether the instrument has anti-dilution / ratchet protection."
    end

    attribute :has_death_spiral_convertible, :boolean do
      public? true
      default false
      description "Whether convertible terms reset based on market price (death-spiral pattern)."
    end

    attribute :is_reverse_split_proxy, :boolean do
      public? true
      default false
      description "Whether a DEF 14A proxy proposes a reverse split."
    end

    attribute :reverse_split_ratio, :string do
      public? true
      description ~s(Reverse-split ratio when proposed, e.g. "1:10".)
    end

    attribute :summary, :string do
      public? true
      description "One-line LLM-authored summary suitable for UI cards."
    end

    attribute :extracted_keywords, :map do
      public? true

      description """
      Tier 1 (LON-134) output — the full validated LLM extraction stored
      as jsonb for audit + as the source-of-truth feeding Tier 2 scoring.
      The individual `:dilution_type`/`:deal_size_usd`/... columns above
      are projections of this map written at the same time, kept for
      composite-index and joinable-query purposes. `nil` when the row
      represents a Tier 1 failure (extractor never produced validated
      output).
      """
    end

    # ── Severity verdict (from Stage 3b Scoring) ──────────────────
    attribute :dilution_severity, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:critical, :high, :medium, :low, :none]

      description """
      Final severity from `Filings.Scoring`. Never asked of the LLM —
      derived deterministically from `SeverityRules`. `:none` means
      either validation rejected the extraction or no rule fired. `nil`
      means Tier 2 (LON-134) has not run yet — the row is in the
      Tier-1-only state that the proactive extractor (LON-135) leaves
      until a trader's on-demand request (LON-136) triggers scoring.
      """
    end

    attribute :matched_rules, {:array, :atom} do
      public? true
      default []
      description "Rule names that fired during scoring, listed for audit."
    end

    attribute :severity_reason, :string do
      public? true
      description "Human-readable reason from the highest-severity matched rule."
    end

    # ── Quality + rejection ───────────────────────────────────────
    attribute :extraction_quality, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:high, :medium, :rejected]

      description """
      `:high` — validation passed; `:rejected` — validation rejected
      the extraction (filer CIK mismatch, implausible numbers, etc.);
      `:medium` reserved for the LON-121 calibration program.
      """
    end

    attribute :rejected_reason, :string do
      public? true
      description "Set only when `:extraction_quality = :rejected`. `Validation` check name + context."
    end

    # ── Flags (cross-cutting signals) ─────────────────────────────
    attribute :flags, {:array, :atom} do
      public? true
      default []

      description """
      Reserved for cross-cutting signals (Stage 9 Form 4 cross-reference,
      future calibration tags). Phase 1 leaves this `[]` — the boolean
      attributes already carry the same per-filing information.
      """
    end

    # ── LLM provenance ────────────────────────────────────────────
    attribute :provider, :string do
      allow_nil? false
      public? true
      description "AI provider module name that produced the extraction."
    end

    attribute :model, :string do
      allow_nil? false
      public? true
      description ~s(Provider model id, e.g. "claude-haiku-4-5".)
    end

    attribute :raw_response, :map do
      public? true
      description "Full LLM response payload preserved for audit + cost analysis."
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
      `(ticker_id, dilution_severity)` index can serve ticker-scoped
      severity queries without a join.
      """
    end
  end

  # Tier 1 (LON-134) writable attrs — set by `Analyzer.extract_keywords/2`.
  # `:extraction_quality` and `:rejected_reason` also appear in `@tier_2_attrs`
  # because Tier 2 scoring can downgrade a `:high` to `:rejected` when
  # scoring-side validation fails (e.g. filer CIK mismatch).
  @tier_1_attrs [
    :extracted_keywords,
    :dilution_type,
    :deal_size_usd,
    :share_count,
    :pricing_method,
    :pricing_discount_pct,
    :warrant_strike,
    :warrant_term_years,
    :atm_remaining_shares,
    :atm_total_authorized_shares,
    :shelf_total_authorized_usd,
    :shelf_remaining_usd,
    :convertible_conversion_price,
    :has_anti_dilution_clause,
    :has_death_spiral_convertible,
    :is_reverse_split_proxy,
    :reverse_split_ratio,
    :summary,
    :extraction_quality,
    :rejected_reason,
    :flags,
    :provider,
    :model,
    :raw_response
  ]

  # Tier 2 (LON-134) writable attrs — set by `Analyzer.score_severity/2`.
  @tier_2_attrs [
    :dilution_severity,
    :matched_rules,
    :severity_reason,
    :extraction_quality,
    :rejected_reason
  ]

  # Used by the test-factory `:create` action — full surface, no upsert.
  @fields [
    :filing_id,
    :ticker_id,
    :extracted_keywords,
    :dilution_type,
    :deal_size_usd,
    :share_count,
    :pricing_method,
    :pricing_discount_pct,
    :warrant_strike,
    :warrant_term_years,
    :atm_remaining_shares,
    :atm_total_authorized_shares,
    :shelf_total_authorized_usd,
    :shelf_remaining_usd,
    :convertible_conversion_price,
    :has_anti_dilution_clause,
    :has_death_spiral_convertible,
    :is_reverse_split_proxy,
    :reverse_split_ratio,
    :summary,
    :dilution_severity,
    :matched_rules,
    :severity_reason,
    :extraction_quality,
    :rejected_reason,
    :flags,
    :provider,
    :model,
    :raw_response
  ]

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept @fields
    end

    create :upsert_tier_1 do
      description """
      Tier 1 write — extraction facts (or extractor-side failure
      record). Called by `Analyzer.extract_keywords/2`. Re-running on
      the same filing overwrites the extraction state but leaves any
      Tier 2 fields already filled in by `:update_tier_2` intact
      (they aren't in `upsert_fields`).
      """

      upsert? true
      upsert_identity :unique_filing_analysis

      accept [:filing_id, :ticker_id | @tier_1_attrs]

      upsert_fields @tier_1_attrs ++ [:analyzed_at]

      change set_attribute(:analyzed_at, &DateTime.utc_now/0)
    end

    update :update_tier_2 do
      description """
      Tier 2 write — fills in the severity verdict on a Tier-1 row.
      Called by `Analyzer.score_severity/2`. May overwrite
      `:extraction_quality` to `:rejected` when scoring-side
      validation fails (e.g. filer CIK mismatch, implausible numbers).
      """

      accept @tier_2_attrs
    end

    read :get_by_filing do
      get? true
      argument :filing_id, :uuid, allow_nil?: false
      filter expr(filing_id == ^arg(:filing_id))
    end

    read :by_ticker do
      description """
      All FilingAnalyses for a ticker, newest first. Optional severity
      filter narrows to e.g. `:critical` for the dilution profile UI.
      Backed by the `(ticker_id, dilution_severity)` composite index.
      """

      argument :ticker_id, :uuid, allow_nil?: false
      argument :severity, :atom, allow_nil?: true

      filter expr(
               ticker_id == ^arg(:ticker_id) and
                 (is_nil(^arg(:severity)) or dilution_severity == ^arg(:severity))
             )

      prepare build(sort: [id: :desc])
    end

    read :recent do
      description """
      Recent FilingAnalysis rows across all tickers. Ordered by `id`
      desc — UUIDv7 keyset cursor is microsecond-tie-safe (see
      `LongOrShort.News.Article` moduledoc for full rationale).
      """

      pagination keyset?: true, required?: false, default_limit: 30

      prepare build(sort: [id: :desc])
    end

    read :pending_tier_2 do
      description """
      Tier-1-only rows awaiting severity scoring (LON-136). Filter:
      `extraction_quality == :high AND dilution_severity IS NULL`.
      Optional `ticker_id` argument narrows to one ticker, used by the
      `mix dilution.score_severity` calibration task. Default limit
      matches the `FilingSeverityWorker` batch size.
      """

      argument :ticker_id, :uuid, allow_nil?: true

      pagination keyset?: true, required?: false, default_limit: 100

      filter expr(
               extraction_quality == :high and is_nil(dilution_severity) and
                 (is_nil(^arg(:ticker_id)) or ticker_id == ^arg(:ticker_id))
             )

      prepare build(sort: [analyzed_at: :asc])
    end
  end

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
