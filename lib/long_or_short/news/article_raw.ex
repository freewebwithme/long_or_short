defmodule LongOrShort.News.ArticleRaw do
  @moduledoc """
  Cold storage for the raw API payload of a `LongOrShort.News.Article`.

  Source adapters (`Sources.{Finnhub, Alpaca, SecEdgar, Dummy}`) preserve
  the original `parse_response/1` input here so debugging, re-analysis,
  and source-bug forensics have ground-truth access to what we ingested.

  Split out from `articles` (hot table) because:

    * The hot path (per-ticker timeline scans, NewsAnalysis joins) never
      reads raw. Keeping it inline would bloat row size for no gain.
    * `jsonb` gets TOAST-compressed transparently — cheap to store.
    * Per-row 1:1 with FK `on_delete: :delete` keeps lifecycle trivial.

  ## Lifecycle

  Populated by `Sources.Pipeline` immediately after a successful
  `News.ingest_article` call (LON-32). Failure here is **fail-soft** —
  Pipeline logs a warning and counts the ingest as success, because raw
  preservation is not on the critical path.

  Cascade-deleted when the parent `Article` is destroyed
  (`on_delete: :delete` on the FK).

  ## Upsert semantics

  Unlike `LongOrShort.Filings.FilingRaw` (one-shot create — filings are
  immutable), polling re-emits the same article repeatedly. ArticleRaw
  upserts on `:article_id` so the latest raw replaces the previous one
  on each poll. This mirrors `Article`'s own last-writer-wins upsert
  behavior — feeders may re-emit corrected payloads.

  ## Retention

  Permanent for now. Re-evaluate when volume becomes a concern; see the
  follow-up Linear ticket scheduled 2026-11-11.
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.News,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "articles_raw"
    repo LongOrShort.Repo

    references do
      reference :article, on_delete: :delete, on_update: :update
    end
  end

  identities do
    identity :unique_article, [:article_id]
  end

  attributes do
    uuid_v7_primary_key :id

    create_timestamp :fetched_at

    attribute :raw_payload, :map do
      allow_nil? false
      public? true
      description "Original API response payload as parsed JSON. Mapped to Postgres `jsonb` (TOAST-compressed)."
    end
  end

  relationships do
    belongs_to :article, LongOrShort.News.Article do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    # Upsert on :unique_article — Pipeline calls this every poll cycle for
    # the same article. Latest raw wins; matches Article's own last-writer-wins
    # upsert on re-emit. `fetched_at` is intentionally NOT in upsert_fields so
    # it preserves first-capture semantics (consistent with `create_timestamp`).
    create :create do
      primary? true
      accept [:article_id, :raw_payload]

      upsert? true
      upsert_identity :unique_article
      upsert_fields [:raw_payload]
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Policies — same shape as FilingRaw. SystemActor (Pipeline) writes;
  # traders read for debugging.
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
