# Domain Info

## `LongOrShort.Tickers`

Master data for stock tickers. Created on-demand by feeders (when an article references a new symbol) and enriched out-of-band.

### `Ticker`

`lib/long_or_short/tickers/ticker.ex` — table `tickers`

#### Attributes (summary)
- `:id` — `uuid_v7`
- `:symbol` — string, **uppercase**, unique identity (`:unique_symbol`)
- `:company_name` — string, optional
- `:exchange` — string (e.g. `"NASDAQ"`)
- `:industry` — string
- `:shares_outstanding`, `:avg_volume_30d` — float
- `:last_price`, `:last_price_updated_at` — float / timestamp
- `:is_active` — boolean (default `true`)

#### Key actions
- **`:create`** — primary create
- **`:upsert_by_symbol`** — upsert on `:unique_symbol`. Used by `Article.:ingest` via `manage_relationship` when a new symbol shows up.
- **`:update_price`** — separate update action that sets `:last_price` and `:last_price_updated_at` together
- **`:active`** — read action filtered to `is_active == true`

#### Code interface (on `LongOrShort.Tickers` domain)
```elixir
create_ticker/1
update_ticker/1
update_ticker_price/2          # args: [:last_price]
upsert_ticker_by_symbol/1
get_ticker_by_symbol/1         # args: [:symbol]
list_active_tickers/0
list_tickers/0
destroy_ticker/1
```

#### Policies
- `bypass actor_attribute_equals(:system?, true)` — feeders bypass
- Admin role: full write access
- Authenticated trader: read-only

---

## `LongOrShort.News`

Articles ingested from external sources. The hot table — most queries hit it.

### `Article`

`lib/long_or_short/news/article.ex` — table `articles`

#### Per-ticker row duplication
When a source article tags multiple tickers (e.g. "BTBD, MSTR, RIOT all rally"), the feeder splits it into one row per ticker. Per-ticker timeline queries (`WHERE ticker_id = X ORDER BY published_at DESC`) become trivial. Trade-off: title text is duplicated, accepted for MVP.

#### Identity
`:unique_source_external_ticker` — `[:source, :external_id, :ticker_id]`

#### Attributes (summary)
- `:id` — `uuid_v7`
- `:source` — atom enum: `[:benzinga, :finnhub, :sec, :pr_newswire, :other]`
- `:external_id` — string, source's own id
- `:title`, `:summary`, `:url`, `:raw_category` — string
- `:sentiment` — atom enum: `[:positive, :negative, :neutral, :unknown]`
- `:content_hash` — SHA-256 of `title + summary`, populated by `ComputeContentHash` change. Used for "did the content actually change?" comparison (LON-54).
- `:published_at` — utc_datetime_usec, source's publish time
- `:fetched_at` — `create_timestamp`, **preserved on re-ingest** (timeline ordering stays stable)
- `:updated_at` — `update_timestamp`

#### Key actions

**`:create`** (primary)
- Direct create with `:ticker_id` already resolved
- Used internally; feeders prefer `:ingest`

**`:ingest`** — the feeder action
- Upsert on `:unique_source_external_ticker`
- Takes a `:symbol` argument (string), resolves to Ticker via `manage_relationship`:
  ```elixir
  manage_relationship(:symbol, :ticker,
    value_is_key: :symbol,
    on_lookup: :relate,
    on_no_match: {:create, :upsert_by_symbol},
    use_identities: [:unique_symbol]
  )
  ```
- `upsert_fields: [:title, :summary, :url, :raw_category, :sentiment, :content_hash]` — content fields are last-writer-wins; identity columns and `published_at`/`fetched_at` are preserved
- Runs `ComputeContentHash` change

**`:by_ticker`** — read with required `:ticker_id` argument, sorted by `published_at` desc

**`:recent`** — read with `:limit` argument (default 50), sorted by `published_at` desc

**`:get_content_hash`** — (planned, LON-54) lightweight read returning only `content_hash` for a given identity, used by Pipeline for broadcast gating

#### Code interface (on `LongOrShort.News` domain)
```elixir
create_article/1
ingest_article/1               # the feeder workhorse
get_article/1                  # get_by: [:id]
list_articles/0
list_articles_by_ticker/1      # args: [:ticker_id]
list_recent_articles/0
destroy_article/1
```

#### Policies
- `bypass actor_attribute_equals(:system?, true)` — feeders bypass
- Admin role: full
- Authenticated trader: `action_type(:read)` allowed

### `News.Dedup`

`lib/long_or_short/news/dedup.ex` — pre-DB dedup GenServer

- ETS table `:news_seen` (public, named, set type)
- Key: `:crypto.hash(:sha256, "#{source}|#{external_id}|#{symbol}")`
- Value: insertion timestamp (millisecond)
- TTL: 24h (configurable via `:news_dedup_ttl_seconds`)
- Cleanup runs hourly via `Process.send_after`

API:
- `Dedup.check_and_mark(source, external_id, symbol)` — returns `true` if newly inserted, `false` if already seen
- `Dedup.seen?/3` — read-only check

### `News.Events`

`lib/long_or_short/news/events.ex` — single source of truth for PubSub topic strings

```elixir
@topic "news:articles"

def subscribe, do: Phoenix.PubSub.subscribe(LongOrShort.PubSub, @topic)
def broadcast_new_article(article),
  do: Phoenix.PubSub.broadcast(LongOrShort.PubSub, @topic, {:new_article, article})
```

---

## `LongOrShort.Sources` (planned, LON-53)

Per-source polling metadata, persisted across restarts.

### `SourceState` (to be created)

- Primary key: `:source` (atom enum)
- `:last_success_at` — utc_datetime_usec
- `:last_error` — string

Used by Finnhub (LON-55) to compute incremental fetch range, eliminating the "re-fetch last 3 days on every restart" problem.

---

## `LongOrShort.Accounts`

Authentication and user roles.

### `User`

`lib/long_or_short/accounts/user.ex` — table `users`

#### Attributes (summary)
- `:id` — `uuid_v7`
- `:email` — `ci_string`, unique identity (`:unique_email`)
- `:hashed_password` — string, sensitive
- `:confirmed_at` — utc_datetime_usec
- `:role` — atom enum: `[:admin, :trader]`, default `:trader`

#### Authentication
- AshAuthentication extension
- Strategies: `:password` (bcrypt) + `:remember_me`
- Magic link removed (LON-47)
- Confirmation: `confirm_on_create? true`, sender `LongOrShort.Accounts.User.Senders.SendNewUserConfirmationEmail`
- Password reset wired up

#### Key actions
- `:register_with_password`, `:sign_in_with_password`, `:sign_in_with_token`
- `:change_password`, `:request_password_reset_token`, `:reset_password_with_token`
- `:get_by_subject` (JWT subject lookup), `:get_by_email`

### `SystemActor`

`lib/long_or_short/accounts/system_actor.ex` — non-Ash plain struct

```elixir
%SystemActor{system?: true, name: "system"}
```

Used by feeders and background jobs as the `actor:` argument to bypass policies. **MVP shortcut** — anyone can construct one. LON-15 tracks the migration to `public? false` + `private_action?()`.

---

## Domain registration

Domains registered in `config :long_or_short, :ash_domains`:

```elixir
[
  LongOrShort.Tickers,
  LongOrShort.News,
  LongOrShort.Accounts,
  LongOrShort.Sources    # planned, LON-53
]
```
