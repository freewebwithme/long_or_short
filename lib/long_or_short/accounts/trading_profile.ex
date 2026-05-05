defmodule LongOrShort.Accounts.TradingProfile do
  @moduledoc """
  Per-user trader profile that drives prompt personalization in
  `LongOrShort.AI.Prompts.MomentumAnalysis` (LON-81/LON-82) and — in
  Phase 2 — rule-based `:strategy_match` evaluation in
  `LongOrShort.Analysis.MomentumAnalysis`.

  One profile per user, enforced by the `:unique_user` identity. The
  user manages their own profile (a settings UI is a follow-up;
  Phase 1 seeds it via `priv/repo/seeds.exs`).

  ## Why broad-with-default schema

  Initial design assumed news-trading users were exclusively small-cap
  momentum day traders. Market research (LON-88) showed otherwise:

    * Among news-active retail (Stocktwits-style audience), day
      traders are ~15%; swing 29%; long-term 48%.
    * Benzinga Pro and similar paid platforms market to day + swing +
      options as named segments, not just momentum scalpers.

  So the schema generalizes along a `:trading_style` axis while
  keeping momentum (`:momentum_day`) as the polished default. The
  style-specific fields (`:price_min/max`, `:float_max`, `:rvol_min`,
  `:patterns_watched`) are nullable — populated when the trader's
  style needs them, ignored otherwise. The prompt builder renders
  only the fields that are present.

  ## Field categories

      * **Core** — apply to every style: `:trading_style`,
        `:time_horizon`, `:market_cap_focuses`, `:catalyst_preferences`,
        `:notes`.
      * **Style-specific (nullable)** — typically populated by
        momentum/small-cap focused traders, ignored otherwise:
        `:price_min`, `:price_max`, `:float_max`.

    More niche style-specific fields (relative volume thresholds,
    pattern preferences, etc.) belong in a separate
    `MomentumStrategyConfig`-style resource keyed off this profile —
    not added until Phase 2 rule-based `:strategy_match` work needs
    them.
  ## Policies

  SystemActor and admins bypass all checks. Trader role can read and
  create/upsert — this **differs from**
  `LongOrShort.Analysis.MomentumAnalysis` (where writes happen via
  SystemActor only) because TradingProfile is user-owned configuration,
  not system output. LON-15 will tighten the trader policy to "only
  their own profile" once auth hardens; Phase 1 single-user makes
  this moot.
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "trading_profiles"
    repo LongOrShort.Repo

    references do
      reference :user, on_delete: :restrict, on_update: :update
    end
  end

  identities do
    identity :unique_user, [:user_id]
  end

  attributes do
    uuid_v7_primary_key :id
    create_timestamp :created_at
    update_timestamp :updated_at

    # ── Core (apply to all trading styles) ──────────────────────────
    attribute :trading_style, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:momentum_day, :large_cap_day, :swing, :position, :options]

      description """
      Primary trading style. Drives the persona-specific guidance the
      prompt builder injects into the system prompt.
      """
    end

    attribute :time_horizon, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:intraday, :multi_day, :multi_week, :multi_month]
      description "Typical hold duration; shapes how the LLM frames continuation vs fade risk."
    end

    attribute :market_cap_focuses, {:array, :atom} do
      allow_nil? false
      public? true
      default []
      constraints items: [one_of: [:micro, :small, :mid, :large]]

      description """
      Market-cap segments the trader focuses on. Empty list = no
      preference. SEC-style buckets: micro (<$300M), small ($300M–$2B),
      mid ($2B–$10B), large ($10B+).
      """
    end

    attribute :catalyst_preferences, {:array, :atom} do
      allow_nil? false
      public? true
      default []

      constraints items: [
                    one_of: [
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
                      :analyst,
                      :macro,
                      :sector,
                      :other
                    ]
                  ]

      description """
      Catalyst types the trader cares about. Subset of
      `MomentumAnalysis.catalyst_type` plus `:analyst`, `:macro`,
      `:sector` (relevant to large-cap day / swing / position users).
      """
    end

    attribute :notes, :string do
      public? true
      description "Free-form addendum appended to the system prompt when present."
    end

    # ── Style-specific (nullable; populated when relevant) ──────────
    attribute :price_min, :decimal do
      public? true
      description "Lower bound of price band (typically momentum/small-cap traders)."
    end

    attribute :price_max, :decimal do
      public? true
      description "Upper bound of price band."
    end

    attribute :float_max, :integer do
      public? true
      description "Maximum float in shares (typically momentum/small-cap traders)."
    end
  end

  relationships do
    belongs_to :user, LongOrShort.Accounts.User do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  @fields [
    :user_id,
    :trading_style,
    :time_horizon,
    :market_cap_focuses,
    :catalyst_preferences,
    :notes,
    :price_min,
    :price_max,
    :float_max
  ]
  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept @fields
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_user

      accept @fields

      upsert_fields [
        :trading_style,
        :time_horizon,
        :market_cap_focuses,
        :catalyst_preferences,
        :notes,
        :price_min,
        :price_max,
        :float_max
      ]
    end

    read :get_by_user do
      get? true
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
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

    # Trader can manage their own trading profile — TradingProfile is
    # user-owned config, not system output. Phase 1 single-user, so
    # `actor_present()` is sufficient. LON-15 will tighten this to
    # "only the profile's own user" once auth is hardened.
    policy action_type([:create, :update]) do
      authorize_if actor_present()
    end
  end
end
