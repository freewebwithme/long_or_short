defmodule LongOrShort.Tickers.Ticker do
  @moduledoc """
  Master data for a tradable symbol.

  Serves as the reference hub for external data sources (Benzinga, SEC,
  Alpha Vantage) and internal resources (Article, NewsAnalysis,
  PriceReaction).

  Price-related hot fields (`last_price`, `avg_volume_30d`) are stored
  directly on this resource for cheap dashboard reads. Historical price
  time series will live in a separate `PriceBar` resource.

  ## Authorization

    - `:system` actors (background feeders) bypass all policies.
    - `:admin` users have full read/write access.
    - Other authenticated users may read only.
    - Unauthenticated requests are forbidden.
  """
  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Tickers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "tickers"
    repo LongOrShort.Repo
  end

  identities do
    identity :unique_symbol, [:symbol]
  end

  attributes do
    uuid_v7_primary_key :id

    create_timestamp :inserted_at
    update_timestamp :updated_at

    attribute :symbol, :string do
      allow_nil? false
      public? true
      description "Trading symbol (e.g. NVDA, AAPL). Normailzed to uppercase"
    end

    attribute :company_name, :string, public?: true

    attribute :exchange, :atom do
      public? true
      constraints one_of: [:nasdaq, :nyse, :amex, :otc, :other]
    end

    attribute :sector, :string, public?: true
    attribute :industry, :string, public?: true

    attribute :float_shares, :integer do
      public? true
      description "Free float, Core input for filter by float"
    end

    attribute :shares_outstanding, :integer, public?: true

    attribute :last_price, :decimal do
      public? true
      description "Most recent observed price."
    end

    attribute :last_price_updated_at, :utc_datetime_usec, public?: true

    attribute :avg_volume_30d, :integer do
      public? true
      description "30-day average volume. Baseline for Relative Volume."
    end

    attribute :is_active, :boolean do
      allow_nil? false
      default true
      public? true
      description "False for delisted or halted symbols."
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :symbol,
        :company_name,
        :exchange,
        :sector,
        :industry,
        :float_shares,
        :shares_outstanding,
        :last_price,
        :last_price_updated_at,
        :avg_volume_30d,
        :is_active
      ]

      change {LongOrShort.Tickers.Changes.UpcaseSymbol, []}
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :company_name,
        :exchange,
        :sector,
        :industry,
        :float_shares,
        :shares_outstanding,
        :avg_volume_30d,
        :is_active
      ]
    end

    update :update_price do
      require_atomic? false
      accept [:last_price]

      change set_attribute(:last_price_updated_at, &DateTime.utc_now/0)
    end

    # Upsert by symbol — used when syncing from external APIs that may or
    # may not have the symbol already in the DB.
    create :upsert_by_symbol do
      upsert? true
      upsert_identity :unique_symbol

      accept [
        :symbol,
        :company_name,
        :exchange,
        :sector,
        :industry,
        :float_shares,
        :shares_outstanding,
        :avg_volume_30d,
        :is_active
      ]

      change {LongOrShort.Tickers.Changes.UpcaseSymbol, []}
    end

    read :by_symbol do
      argument :symbol, :string, allow_nil?: false
      get? true
      filter expr(symbol == ^arg(:symbol))
    end

    read :active do
      filter expr(is_active == true)
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Policies
  # ─────────────────────────────────────────────────────────────────────
  #
  # Evaluation order (top to bottom):
  #   1. System actor bypass — background feeders do anything.
  #   2. Admin bypass         — human admins do anything.
  #   3. Read policy          — any authenticated actor may read.
  #   4. Default              — everything else is forbidden.
  #
  policies do
    # Background jobs (GenServer feeders, seeders) run as `:system`.
    # They must be able to upsert symbols, update prices, etc.
    bypass actor_attribute_equals(:system?, true) do
      authorize_if always()
    end

    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    policy action_type(:read) do
      forbid_if actor_absent()
      authorize_if always()
    end
  end
end
