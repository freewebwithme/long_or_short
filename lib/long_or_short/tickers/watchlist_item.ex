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
    user × ticker returns the existing row without error. After commit,
    enqueues a `Filings.Workers.FilingAnalysisBackfillWorker` job so
    the dilution-profile UI is populated immediately for the newly
    watched ticker (LON-115).
  - `:destroy` (default) — hard delete by item ID.
  - `:list_for_user` — all items for a given user, ordered newest first,
    with `:ticker` pre-loaded.
  - `:list_all` — every item across all users, with `:ticker` pre-loaded.
    System-only; intended for global derived state (e.g. the live-price
    WebSocket subscription union). Cross-user reads must use
    `authorize?: false`.

  ## Policies

  SystemActor and admins bypass all checks. Traders can only act on
  their own watchlist rows — verified per-action via the policy
  expressions below (LON-138).

  `:list_all` has no trader-facing policy clause; it falls through to
  default-forbidden and is only reachable via system/admin bypass.
  """

  require Logger

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

      # Ownership scoping for create — Ash policy `authorize_if expr(...)`
      # cannot reference changeset attributes on a create action (the
      # row doesn't exist yet). Shared validation enforces the
      # trader-can-only-create-for-self invariant; system/admin bypass.
      validate LongOrShort.Validations.OwnedByActor

      # Enqueue a dilution-analysis backfill for the ticker so the
      # /dilution UI is populated immediately rather than waiting for
      # the next watchlist cron sweep (LON-115). The worker is
      # `unique:` on `:ticker_id`, so multi-user adds for the same
      # ticker collapse to one backfill. An Oban insert failure
      # warns but does not fail the watchlist add — the cron worker
      # will pick up new filings within 15 minutes regardless.
      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, item ->
          item.ticker_id
          |> LongOrShort.Filings.Workers.FilingAnalysisBackfillWorker.new_job()
          |> Oban.insert()
          |> case do
            {:ok, _job} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "WatchlistItem.add: failed to enqueue analysis backfill for ticker " <>
                  "#{item.ticker_id} — #{inspect(reason)}"
              )
          end

          {:ok, item}
        end)
      end
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

    # Trader can read their own watchlist. `:list_all` has no clause
    # here and is forbidden unless the system/admin bypass above fires.
    policy action(:list_for_user) do
      authorize_if expr(^arg(:user_id) == ^actor(:id))
    end

    # Trader can add only to their own watchlist. The ownership check
    # itself runs as an in-action validation (see :add) because Ash
    # policies cannot reference changeset attributes on create. This
    # policy gates anonymous callers.
    policy action(:add) do
      authorize_if actor_present()
    end

    # Trader can destroy only their own rows.
    policy action_type(:destroy) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end
end
