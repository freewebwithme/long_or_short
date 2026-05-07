defmodule LongOrShort.Tickers.WatchlistItem do
  @moduledoc """
  A per-user watchlist entry joining a trader to a tracked ticker.

  This is the DB-backed, dynamic counterpart to the static
  `priv/tracked_tickers.txt` ingestion universe. Each row records one
  ticker the trader wants to follow; the user can add/remove entries
  without an app restart.

  ## Schema

  - Identity: `unique_user_ticker` on `[:user_id, :ticker_id]` — one row
    per user × ticker pair.
  - `notify?` is a placeholder for the LON-86 price-alert epic. It is
    stored but not consumed yet.

  ## Actions

  - `:add` — idempotent upsert. Calling it twice for the same
    user × ticker returns the existing row without error.
  - `:destroy` (default) — hard delete by item ID.
  - `:list_for_user` — all items for a given user, ordered newest first,
    with `:ticker` pre-loaded.
  - `:list_all` — every item across all users, with `:ticker` pre-loaded.
    System-only; intended for global derived state (e.g. the live-price
    WebSocket subscription union). Cross-user reads must use
    `authorize?: false`.

  ## Policies

  Mirror `TradingProfile` policy structure — SystemActor and admins
  bypass all checks; traders can read, create, and destroy. LON-15 will
  tighten the trader destroy policy to own-row-only once auth hardens.
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Tickers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "watchlist_items"
    repo LongOrShort.Repo

    references do
      reference :user, on_delete: :delete, on_update: :update
      reference :ticker, on_delete: :restrict, on_update: :update
    end
  end

  identities do
    identity :unique_user_ticker, [:user_id, :ticker_id]
  end

  attributes do
    uuid_v7_primary_key :id
    create_timestamp :created_at
    update_timestamp :updated_at

    attribute :notify?, :boolean do
      allow_nil? false
      default false
      public? true
      description "Placeholder for LON-86 price-alert integration. Not consumed yet."
    end
  end

  relationships do
    belongs_to :user, LongOrShort.Accounts.User do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :ticker, LongOrShort.Tickers.Ticker do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :add do
      primary? true

      accept [:user_id, :ticker_id]

      upsert? true
      upsert_identity :unique_user_ticker

      # :updated_at is a benign no-op write that ensures Postgres returns
      # the existing row on conflict rather than silently discarding it.
      upsert_fields [:updated_at]
    end

    read :list_for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
      prepare build(sort: [created_at: :desc], load: [:ticker])
    end

    read :list_all do
      prepare build(sort: [created_at: :asc], load: [:ticker])
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

    policy action_type(:create) do
      authorize_if actor_present()
    end

    # Phase 1: any authenticated actor can destroy any item.
    # LON-15 will tighten to own-row-only.
    policy action_type(:destroy) do
      authorize_if actor_present()
    end
  end
end
