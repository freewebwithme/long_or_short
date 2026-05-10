defmodule LongOrShort.Analysis.NewsAnalysis do
  @moduledoc """
  Multi-axis momentum analysis of one news article — output of
  `LongOrShort.Analysis.MomentumAnalyzer` (LON-82). One row per article.

  ## Card UX

  The compact card shows six signals plus a headline takeaway, scannable in
  under a second:

    - `:catalyst_strength`, `:catalyst_type`, `:sentiment`
    - `:pump_fade_risk`, `:strategy_match`, `:verdict`
    - `:headline_takeaway` — one-line trader-voice summary

  The expandable detail view renders five Markdown sections: `:detail_summary`,
  `:detail_positives`, `:detail_concerns`, `:detail_checklist`,
  `:detail_recommendation`.

  See LON-78 epic for design rationale and target card layout.

  ## Lifecycle

  One row per article, enforced by the `:unique_article` identity on
  `:article_id`. Use `:create` for the first analysis, `:upsert` for
  re-analysis — the same row is overwritten and `:analyzed_at` advances.
  Older runs are not retained as history rows. Deliberate divergence from
  `RepetitionAnalysis`, which keeps a row per run.

  ## Field categories

    - **Card signals** — typed enum axes that drive the compact card
    - **Card summary** — `:headline_takeaway`
    - **Detail view** — five Markdown sections for the expanded view
    - **Snapshot at analysis time** — `:price_at_analysis`,
      `:float_shares_at_analysis`, `:rvol_at_analysis`. Frozen at create —
      what the trader was looking at when they clicked Analyze.
    - **Dilution snapshot at analysis time** (LON-117) —
      `:dilution_severity_at_analysis`, `:dilution_flags_at_analysis`,
      `:dilution_summary_at_analysis`. Mirrors the profile shape from
      `LongOrShort.Tickers.get_dilution_profile/1` at the moment the
      LLM produced its verdict, so we can later query
      "show all SHORT verdicts where dilution was critical" without
      re-aggregating filings, and re-running calibration against the
      exact context the LLM saw.
    - **Strategy-match reasoning** — `:strategy_match_reasons` JSON
      breakdown of which rules passed/failed
    - **LLM provenance** — `:llm_provider`, `:llm_model`, `:input_tokens`,
      `:output_tokens`, `:raw_response` for cost tracking (LON-35 epic),
      model-drift detection, and full audit re-running.

  ## LLM fills LLM-shaped fields, code fills code-shaped fields

  The LLM populates LLM-shaped fields (catalyst, sentiment, verdict, detail
  sections, takeaway). Code-shaped fields are Phase 1 stubs:

    - `:pump_fade_risk` defaults to `:insufficient_data` — Phase 4 fills it
      from a `price_reactions` history table.
    - `:strategy_match` defaults to `:partial` — Phase 2 fills it from
      deterministic rules over price, float, and RVOL.

  Asking the LLM to guess these from a headline alone produces hallucination,
  so they stay stubbed until real signal sources land.

  ## Policies

  SystemActor (`:system?` true) and admins bypass all checks. Authenticated
  trader users can read but not write — writes happen via `MomentumAnalyzer`
  running as `SystemActor`. LON-15 will replace this bypass pattern.
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Analysis,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "news_analyses"
    repo LongOrShort.Repo

    references do
      reference :article, on_delete: :restrict, on_update: :update
      reference :user, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      # Per-user history is the dominant query after LON-109: the
      # `:recent` action scans `WHERE user_id = ? ORDER BY id DESC` for
      # the /analyze history surface (LON-108). Composite covers both
      # the predicate and the sort.
      index [:user_id, :id], name: "news_analyses_user_id_id_index"
    end
  end

  identities do
    identity :unique_article_user, [:article_id, :user_id]
  end

  attributes do
    uuid_v7_primary_key :id
    create_timestamp :created_at
    update_timestamp :updated_at

    attribute :analyzed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "Wall-clock time the analysis was produced; set by action."
    end

    # ── Card-level signals ──────────────────────────────────────────
    attribute :catalyst_strength, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:strong, :medium, :weak, :unknown]
      description "How strong the catalyst is as a momentum trigger."
    end

    attribute :catalyst_type, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :partnership,
                    :ma,
                    :fda,
                    :earnings,
                    :offering,
                    :rfp,
                    :contract_win,
                    :guidance,
                    :clinical,
                    :regulatory,
                    :other
                  ]

      description "Kind of news event (partnership, M&A, FDA, earnings, …)."
    end

    attribute :sentiment, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:positive, :neutral, :negative]
      description "Directional bias of the news itself."
    end

    attribute :pump_fade_risk, :atom do
      allow_nil? false
      public? true
      default :insufficient_data
      constraints one_of: [:high, :medium, :low, :insufficient_data]

      description """
      Likelihood of a post-spike fade. Phase 1 stub — defaults to
      `:insufficient_data`. Phase 4 will fill the real value from a
      price-reaction history table.
      """
    end

    attribute :repetition_count, :integer do
      allow_nil? false
      public? true
      default 1
      description "Nth occurrence of this theme (this article counted)."
    end

    attribute :repetition_summary, :string do
      public? true

      description ~s(Short label for the repetition cluster, e.g. "Aero Velocity 파트너십 4번째".)
    end

    attribute :strategy_match, :atom do
      allow_nil? false
      public? true
      default :partial
      constraints one_of: [:match, :partial, :skip]

      description """
      Fit with the user's small-cap momentum strategy. Phase 1 stub —
      defaults to `:partial`. Phase 2 will fill the real value from
      rule-based signals on price, float, and RVOL.
      """
    end

    attribute :verdict, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:trade, :watch, :skip]

      description """
      Trader-facing call: `:trade` (take it), `:watch` (monitor),
      `:skip` (pass).
      """
    end

    # ── Card summary ────────────────────────────────────────────────
    attribute :headline_takeaway, :string do
      allow_nil? false
      public? true
      description "One-line trader-voice summary shown on the feed card."
    end

    # ── Detail view (Markdown) ──────────────────────────────────────
    attribute :detail_summary, :string do
      public? true
      description "Detail section: what the news actually says."
    end

    attribute :detail_positives, :string do
      public? true
      description "Detail section: bullish reading and momentum factors."
    end

    attribute :detail_concerns, :string do
      public? true
      description "Detail section: bearish reading and fade risks."
    end

    attribute :detail_checklist, :string do
      public? true

      description """
      Detail section: pre-entry checks (price band, float, RVOL,
      EMA alignment).
      """
    end

    attribute :detail_recommendation, :string do
      public? true
      description "Detail section: concrete suggested action with reasoning."
    end

    # ── Snapshot at analysis time (frozen — never updated after creation) ──
    attribute :price_at_analysis, :decimal do
      public? true
      description "`Ticker.last_price` at the moment Analyze was clicked."
    end

    attribute :float_shares_at_analysis, :integer do
      public? true
      description "`Ticker.float_shares` snapshot at analysis time."
    end

    attribute :rvol_at_analysis, :float do
      public? true
      description "Relative volume snapshot at analysis time."
    end

    attribute :strategy_match_reasons, :map do
      public? true

      description """
      JSON describing which strategy rules passed/failed, e.g.
      `%{"price_in_range" => true, "float_under_50m" => false}`.
      Phase 1 leaves `%{}` since `:strategy_match` is stubbed.
      """
    end

    # ── LLM provenance ──────────────────────────────────────────────
    attribute :llm_provider, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:claude, :mock, :other]
      description "Which provider produced this analysis."
    end

    attribute :llm_model, :string do
      allow_nil? false
      public? true
      description ~s(Provider model id, e.g. "claude-opus-4-7".)
    end

    attribute :input_tokens, :integer do
      public? true
      description "Input token count — cost tracking (LON-35 epic)."
    end

    attribute :output_tokens, :integer do
      public? true
      description "Output token count — cost tracking."
    end

    attribute :raw_response, :map do
      public? true

      description """
      Full LLM response payload preserved for audit + cost analysis +
      reproduction of `:dilution_severity_at_analysis` verdicts during
      LON-121 calibration. The dilution profile injected into the
      prompt is also stashed here under the `"dilution_profile"` key
      so a future re-analysis can reproduce exactly what the LLM saw.
      """
    end

    # ── Dilution snapshot at analysis time (LON-117) ────────────────
    attribute :dilution_severity_at_analysis, :atom do
      allow_nil? false
      public? true
      default :unknown
      constraints one_of: [:none, :low, :medium, :high, :critical, :unknown]

      description """
      Frozen `overall_severity` from the dilution profile at the
      moment the LLM produced its verdict. `:unknown` is used when
      `data_completeness` was `:insufficient` — distinct from
      `:none` (we have data, no rules fired) to keep "data missing"
      from being misread as "definitely clean."
      """
    end

    attribute :dilution_flags_at_analysis, {:array, :atom} do
      allow_nil? false
      public? true
      default []
      description "Frozen `profile.flags` snapshot for queryability."
    end

    attribute :dilution_summary_at_analysis, :string do
      public? true

      description """
      One-line snapshot for display. Format:
      `"<SEVERITY> — <reason>"` when data is present, e.g.
      `"HIGH — ATM > 50% float (12M / 22M shares)"`. Falls back to
      `"Unknown — no dilution data in last 180 days"` when
      `data_completeness` was `:insufficient`.
      """
    end
  end

  relationships do
    belongs_to :article, LongOrShort.News.Article do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :user, LongOrShort.Accounts.User do
      allow_nil? false
      attribute_writable? true
      public? true
      description "Trader who triggered this analysis. Different traders' analyses of the same article are distinct rows (per `:unique_article_user` identity)."
    end
  end

  @fields [
    :article_id,
    :user_id,
    :catalyst_strength,
    :catalyst_type,
    :sentiment,
    :pump_fade_risk,
    :repetition_count,
    :repetition_summary,
    :strategy_match,
    :verdict,
    :headline_takeaway,
    :detail_summary,
    :detail_positives,
    :detail_concerns,
    :detail_checklist,
    :detail_recommendation,
    :price_at_analysis,
    :float_shares_at_analysis,
    :rvol_at_analysis,
    :strategy_match_reasons,
    :llm_provider,
    :llm_model,
    :input_tokens,
    :output_tokens,
    :raw_response,
    :dilution_severity_at_analysis,
    :dilution_flags_at_analysis,
    :dilution_summary_at_analysis
  ]
  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept @fields

      change set_attribute(:analyzed_at, &DateTime.utc_now/0)
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_article_user

      accept @fields

      upsert_fields [
        :catalyst_strength,
        :catalyst_type,
        :sentiment,
        :pump_fade_risk,
        :repetition_count,
        :repetition_summary,
        :strategy_match,
        :verdict,
        :headline_takeaway,
        :detail_summary,
        :detail_positives,
        :detail_concerns,
        :detail_checklist,
        :detail_recommendation,
        :price_at_analysis,
        :float_shares_at_analysis,
        :rvol_at_analysis,
        :strategy_match_reasons,
        :llm_provider,
        :llm_model,
        :input_tokens,
        :output_tokens,
        :raw_response,
        :dilution_severity_at_analysis,
        :dilution_flags_at_analysis,
        :dilution_summary_at_analysis,
        :analyzed_at
      ]

      change set_attribute(:analyzed_at, &DateTime.utc_now/0)
    end

    read :get_by_article do
      get? true
      argument :article_id, :uuid, allow_nil?: false
      filter expr(article_id == ^arg(:article_id))
    end

    read :recent do
      description """
      Recent NewsAnalysis rows for the /analyze history surface
      (LON-108). Ordered by `id` desc — UUIDv7 is timestamp-ordered
      and globally unique, so it produces near-chronological
      ordering by *first analysis time* without the keyset
      precision hazards that hit DateTime sorts.

      ## Why `id` desc and not `analyzed_at` desc

      Sorting by `analyzed_at` was the obvious choice (re-analyzed
      articles would jump to the top), but Ash's keyset cursor
      empirically drops rows on the second page when the sort
      column is a `utc_datetime_usec`. Reproduced reliably with 21
      sequential creates: page 1 returned 20 rows with `more?: true`,
      page 2 returned 0 rows despite 1 unread row. Same class of
      issue documented in `LongOrShort.News.Article.:recent`.

      Trade-off: re-analyzing an old article does not push it to
      the top of the history list. Re-analysis is uncommon in
      practice, and silent row-skipping in pagination is the worse
      data-integrity outcome. UUIDv7 sort gives ~chronological
      order anyway; the only divergence is the re-analyze case.

      ## Per-user scoping (LON-109)

      Per-user scoping is enforced by the trader read policy
      (`expr(user_id == ^actor(:id))`), not by this action's
      filter. Authorized trader callers see only their own rows;
      `authorize?: false` callers (tests, future admin tooling)
      see every row. Keeping the actor-scoping in the policy
      layer means this action's filter stays focused on its own
      semantic argument (`:ticker_id`) and `authorize?: false`
      remains a meaningful escape hatch.

      ## Index

      Backed by `news_analyses_user_id_id_index` —
      `(user_id, id)`. Postgres uses it for the per-user
      `WHERE user_id = ? ORDER BY id DESC` scan that this action
      drives.
      """

      argument :ticker_id, :uuid

      pagination keyset?: true, required?: false, default_limit: 20

      filter expr(
               is_nil(^arg(:ticker_id)) or article.ticker_id == ^arg(:ticker_id)
             )

      prepare build(sort: [id: :desc], load: [article: [:ticker]])
    end
  end

  policies do
    bypass actor_attribute_equals(:system?, true) do
      authorize_if always()
    end

    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    # Trader read scope: a trader sees only their own analyses. The
    # `authorize_if expr(...)` form acts as a filter check — it
    # appends `WHERE user_id = ^actor(:id)` to every read query
    # (and `:get_by_article` / `:recent` / the `Article.news_analysis`
    # has_one all flow through this). LON-15 generalises this
    # own-row pattern across other resources.
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end
end
