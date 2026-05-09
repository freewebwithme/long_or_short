defmodule LongOrShort.Filings.FilingRaw do
  @moduledoc """
  Cold storage for the full body text of a `LongOrShort.Filings.Filing`.

  Split out from `filings` (hot table) so that 100KB+ S-1 bodies never
  bloat per-ticker timeline scans. One `FilingRaw` row per `Filing` —
  enforced by the `:unique_filing` identity on `:filing_id`.

  ## Lifecycle

  Populated by Stage 3a (LON-113), which fetches the filing body via
  the SEC EDGAR document URL after the parent `Filing` row is in place.
  Cascade-deleted when the parent `Filing` is destroyed
  (`on_delete: :delete` on the FK).

  No upsert semantics — filings are immutable once filed. If a fetch
  needs to be retried, callers should `destroy` the old row and create
  a new one.
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Filings,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "filings_raw"
    repo LongOrShort.Repo

    references do
      reference :filing, on_delete: :delete, on_update: :update
    end
  end

  identities do
    identity :unique_filing, [:filing_id]
  end

  attributes do
    uuid_v7_primary_key :id

    create_timestamp :fetched_at

    attribute :raw_text, :string do
      allow_nil? false
      public? true
      description "Full filing body text. Mapped to Postgres `text` by AshPostgres."
    end

    attribute :content_hash, :string do
      allow_nil? false
      public? true
      description "SHA-256 hex digest of `raw_text`. Lets callers compare bodies cheaply."
    end
  end

  relationships do
    belongs_to :filing, LongOrShort.Filings.Filing do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:filing_id, :raw_text, :content_hash]
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Policies — same shape as Filing. SystemActor (Stage 3a fetcher) writes;
  # traders read.
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
