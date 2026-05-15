defmodule LongOrShort.Research.TickerBriefing do
  @moduledoc """
  Per-ticker, per-user on-demand research briefing (LON-172, PT-1 of
  the LON-171 epic).

  Produced by `LongOrShort.Research.BriefingGenerator.generate/3`
  when a trader asks "what should I know about TICKER right now?".
  The generator calls a `Provider.call_with_search/2` (LON-150) and
  upserts the resulting markdown narrative + citations into this
  table.

  ## Why per-user

  Briefings are persona-tuned via the requesting trader's
  `TradingProfile` — same momentum_day persona that drives
  `NewsAnalysis` (LON-78). Two traders asking about the same ticker
  produce different briefings; persisting per-user keeps each one's
  read history clean and avoids accidental persona crossover when a
  multi-trader setup arrives later.

  Snapshotting the `trading_profile_snapshot` map at generation time
  is intentional: the trader may edit their profile next week, and we
  want the briefing to reflect "the persona at the time of the call,"
  not the current profile.

  ## Caching identity

  `unique_ticker_user_active` on `[:ticker_id, :generated_for_user_id]`
  enforces **latest only** — re-generating overwrites the prior row
  via the `:upsert` action. `cached_until` tells the consumer (PT-3)
  whether the persisted row is still fresh; if expired the Generator
  produces a new one and the same identity slot updates in place.

  History-keeping (every generate landing as a new row) is an
  intentional future option, not the PT-1 default. Reason: PT-1
  scope keeps the resource shape minimal so the Generator + UI work
  on top of a known boundary.

  ## Policies

    * SystemActor + admin — full bypass (Generator persists as system)
    * Authenticated trader — reads ONLY their own briefings; create
      / upsert similarly scoped (caller must match
      `generated_for_user_id`).
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Research,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "ticker_briefings"
    repo LongOrShort.Repo
  end

  identities do
    identity :unique_ticker_user_active, [:ticker_id, :generated_for_user_id]
  end

  attributes do
    uuid_v7_primary_key :id
    create_timestamp :inserted_at
    update_timestamp :updated_at

    attribute :symbol, :string do
      allow_nil? false
      public? true

      description """
      Denormalized ticker symbol for fast lookup paths (the
      `:get_latest_for` read takes `:symbol` directly rather than
      resolving through `Tickers.get_ticker_by_symbol/1` first).
      Always uppercase.
      """
    end

    attribute :narrative, :string do
      allow_nil? false
      public? true
      description "LLM-generated markdown body — the briefing's primary content."
    end

    attribute :structured, :map do
      public? true
      default %{}

      description """
      Optional structured breakdown (`%{catalyst, sentiment, risks,
      confirms}`) parsed out of the LLM response when the prompt
      requests a tool-use return. PT-1 stores `%{}` until the prompt
      adds the structured ask; the field is there so PT-2/4 surfaces
      can render dense summary chips without re-parsing the markdown.
      """
    end

    attribute :citations, {:array, :map} do
      allow_nil? false
      public? true
      default []

      description """
      Deduped, sequentially indexed web_search citations.
      `%{idx, url, title, source, cited_text, accessed_at}` shape —
      matches `MorningBriefDigest.citations`.
      """
    end

    attribute :provider, :atom do
      allow_nil? false
      public? true
      # `:qwen_native` reserved for LON-148-style provider fallback —
      # same forward-compat shape as `MorningBriefDigest`.
      constraints one_of: [:anthropic, :qwen_native, :mock]
      description "Provider label for cost / drift attribution."
    end

    attribute :model, :string do
      allow_nil? false
      public? true
      description ~s(Full model id, e.g. `"claude-sonnet-4-6-20250101"`.)
    end

    attribute :usage, :map do
      allow_nil? false
      public? true
      default %{}

      description """
      `%{input_tokens, output_tokens, search_calls, cache_creation_input_tokens,
      cache_read_input_tokens}` from the provider response. Used for
      per-briefing cost calc and the daily aggregate (PT-3 / dashboard).
      """
    end

    attribute :cached_until, :utc_datetime_usec do
      allow_nil? false
      public? true

      description """
      TTL expiry timestamp populated at generation time. Regular-hours
      briefings get a 12h window, premarket briefings 30 min; the
      Generator picks the policy via current ET wall-clock. PT-3
      wires the consumer (return cached row if `now < cached_until`).
      """
    end

    attribute :trading_profile_snapshot, :map do
      allow_nil? false
      public? true
      default %{}

      description """
      Frozen `TradingProfile` snapshot at generation time —
      `%{trading_style, time_horizon, market_cap_focuses,
      catalyst_preferences, price_min, price_max, float_max, notes}`.
      Lets a stale briefing be reviewed against the persona that
      shaped it, not the trader's current edits.
      """
    end

    attribute :generated_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "Wall-clock time the generation completed; advances on each upsert."
    end
  end

  relationships do
    belongs_to :ticker, LongOrShort.Tickers.Ticker do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :generated_for_user, LongOrShort.Accounts.User do
      allow_nil? false
      attribute_writable? true
      public? true

      description """
      The user whose `TradingProfile` shaped this briefing. Used both
      for policy scoping and for the persona snapshot context.
      """
    end
  end

  @fields [
    :symbol,
    :narrative,
    :structured,
    :citations,
    :provider,
    :model,
    :usage,
    :cached_until,
    :trading_profile_snapshot,
    :ticker_id,
    :generated_for_user_id
  ]

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept @fields
      change set_attribute(:generated_at, &DateTime.utc_now/0)
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_ticker_user_active
      accept @fields

      upsert_fields [
        :narrative,
        :structured,
        :citations,
        :provider,
        :model,
        :usage,
        :cached_until,
        :trading_profile_snapshot,
        :generated_at
      ]

      change set_attribute(:generated_at, &DateTime.utc_now/0)
    end

    read :get_latest_for do
      description """
      The freshest still-valid briefing for `(symbol, user_id)`, or
      `nil` if either no briefing exists or the cached row has
      expired. Generator's cache-hit check uses this directly.
      """

      get? true
      argument :symbol, :string, allow_nil?: false
      argument :user_id, :uuid_v7, allow_nil?: false

      filter expr(
               symbol == ^arg(:symbol) and
                 generated_for_user_id == ^arg(:user_id) and
                 cached_until > now()
             )
    end

    read :by_user do
      description "Recent briefings produced for `user_id`, newest first."
      argument :user_id, :uuid_v7, allow_nil?: false

      pagination keyset?: true, required?: false, default_limit: 30

      filter expr(generated_for_user_id == ^arg(:user_id))
      prepare build(sort: [generated_at: :desc])
    end
  end

  policies do
    bypass actor_attribute_equals(:system?, true) do
      authorize_if always()
    end

    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    # Reads — actor must own the row. The Generator persists as
    # SystemActor (bypass above), so it can write any user's row;
    # but trader read paths can only see their own.
    policy action_type(:read) do
      authorize_if expr(generated_for_user_id == ^actor(:id))
    end

    # Trader-side create/upsert is mostly unused — the Generator
    # writes as SystemActor — but kept symmetric so future UI paths
    # (e.g. "save a draft briefing") have a sane authorization story.
    policy action_type(:create) do
      authorize_if expr(generated_for_user_id == ^actor(:id))
    end
  end
end
