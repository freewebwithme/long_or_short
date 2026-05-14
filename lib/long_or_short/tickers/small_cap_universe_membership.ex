defmodule LongOrShort.Tickers.SmallCapUniverseMembership do
  @moduledoc """
  Records "ticker X is currently in our small-cap universe per source Y"
  as a temporal fact (LON-133, Phase 0 of the two-tier dilution epic).

  The universe is the set of tickers the proactive Tier 1 dilution
  extractor (LON-135, Phase 2) iterates over. Phase 0 only knows one
  source — `:iwm` (iShares Russell 2000 ETF holdings CSV) — but the
  `source` enum is in place so later phases can add `:sec_topup` and
  `:manual` without schema change.

  ## Lifecycle

    1. `IwmUniverseSync` worker downloads the IWM holdings CSV.
    2. For each equity row: upsert a `Ticker`, then call
       `:upsert_observed` — creates a new active membership or bumps
       `last_seen_at` on an existing one.
    3. After the batch: bulk `:deactivate` on rows whose
       `last_seen_at < batch_started_at` (i.e. not seen this run).
    4. If a previously-stale ticker reappears, `:upsert_observed`
       re-activates it. No missed-runs counter — single-shot.

  ## Authorization

    * `:system` actors (sync workers) bypass all policies.
    * `:admin` users have full read/write access.
    * Other authenticated users may read only.
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Tickers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "small_cap_universe_memberships"
    repo LongOrShort.Repo

    references do
      reference :ticker, on_delete: :delete
    end
  end

  identities do
    identity :unique_ticker_source, [:ticker_id, :source]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :source, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:iwm, :sec_topup, :manual]
      description "Where this membership was observed from."
    end

    attribute :first_seen_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "First time the ticker was observed in this source."
    end

    attribute :last_seen_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "Most recent observation in this source."
    end

    attribute :is_active, :boolean do
      allow_nil? false
      default true
      public? true
      description "False once a sync run finishes without observing this row."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :ticker, LongOrShort.Tickers.Ticker do
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :upsert_observed do
      description """
      Upsert by (ticker_id, source). Creates a new active membership or
      bumps `last_seen_at` (and re-activates) on an existing one.
      """

      accept [:ticker_id, :source]

      upsert? true
      upsert_identity :unique_ticker_source
      upsert_fields [:last_seen_at, :is_active]

      change set_attribute(:first_seen_at, &DateTime.utc_now/0)
      change set_attribute(:last_seen_at, &DateTime.utc_now/0)
      change set_attribute(:is_active, true)
    end

    update :deactivate do
      description """
      Flip `is_active` to false. Designed for bulk use — callers filter
      a query (e.g. `last_seen_at < batch_started_at`) then `Ash.bulk_update!`.
      """

      accept []
      change set_attribute(:is_active, false)
    end

    read :list_active do
      filter expr(is_active == true)
      prepare build(load: [:ticker], sort: [inserted_at: :asc])
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
      forbid_if actor_absent()
      authorize_if always()
    end
  end
end
