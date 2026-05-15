# Domain Info

> Last updated: 2026-05-15

## `LongOrShort.Tickers`

Master data for stock tickers. Created on-demand by feeders (when an article references a new symbol), enriched daily by the Finnhub profile sync worker, and linked to SEC EDGAR via the CIK mapping job.

### `Ticker`

`lib/long_or_short/tickers/ticker.ex` — table `tickers`

#### Attributes (summary)
- `:id` — `uuid_v7`
- `:symbol` — string, **uppercase**, unique identity (`:unique_symbol`)
- `:cik` — string (zero-padded 10-digit), unique-where-not-null (`:unique_cik`) — SEC EDGAR Central Index Key
- `:company_name` — string
- `:exchange` — atom enum: `[:nasdaq, :nyse, :amex, :otc, :other]`
- `:sector`, `:industry` — string
- `:float_shares` — integer (free float; FMP follow-up for accuracy — LON-68)
- `:shares_outstanding` — integer
- `:last_price` — decimal
- `:last_price_updated_at` — utc_datetime_usec
- `:avg_volume_30d` — integer (baseline for Relative Volume)
- `:is_active` — boolean (default `true`; `false` for delisted/halted)

#### Identities
- `:unique_symbol` on `[:symbol]`
- `:unique_cik` on `[:cik]` where `cik IS NOT NULL`

#### Key actions
- **`:create`** — primary; runs `UpcaseSymbol` change
- **`:update`** — non-identity, non-price master fields
- **`:update_price`** — accepts `:last_price`, auto-sets `:last_price_updated_at`
- **`:upsert_by_symbol`** — upsert on `:unique_symbol`. Used by feeders, profile sync, and CIK mapper. Excludes `:symbol`, `:is_active`, `:last_price*` from upsert_fields.
- **`:by_symbol`** — read with `:symbol` arg, `get?: true`
- **`:active`** — read filtered to `is_active == true`
- **`:search`** — read with `:query` arg; ilike on symbol/company_name; sorted is_active desc, symbol asc; limit 10

#### Code interface (on `LongOrShort.Tickers` domain)
```elixir
create_ticker/1
update_ticker/1
update_ticker_price/2          # args: [:last_price]
upsert_ticker_by_symbol/1
get_ticker_by_symbol/1         # args: [:symbol]
get_ticker_by_cik/1
list_active_tickers/0
list_tickers/0
search_tickers/1               # args: [:query]
destroy_ticker/1
```

#### Policies
- `bypass actor_attribute_equals(:system?, true)` — feeders / workers bypass
- `bypass actor_attribute_equals(:role, :admin)` — admin full access
- Authenticated traders read-only; unauthenticated forbidden

### `Tickers.Tracked`

`lib/long_or_short/tickers/tracked.ex` — pure module, no persistence (LON-64 / renamed LON-91)

- `symbols/0` — reads `priv/tracked_tickers.txt` (one symbol per line; `#`-prefixed comments ignored)
- Override via `:tracked_tickers_override` env (list of symbols) for tests
- File path: `Application.app_dir(:long_or_short, "priv/tracked_tickers.txt")`
- Used by: `FinnhubStream`, `FinnhubProfileSync`, `IndicesPoller`, `DashboardLive`

This is the **ingestion universe** — tickers we poll for news/profile data, bounded by free-tier rate limits. The per-user dynamic watchlist (LON-90 / LON-92) is a separate DB-backed resource.

### `Tickers.Sources.FinnhubStream`

`lib/long_or_short/tickers/sources/finnhub_stream.ex` — WebSocket client (`WebSockex`), LON-60. Robust lifecycle: LON-67.

- Subscribes to the union of `WatchlistItem` symbols across users + `Tracked.symbols/0` fallback, capped at 50 (Finnhub free tier WebSocket limit)
- Per trade tick: `update_ticker_price/2` + broadcast `{:price_tick, symbol, %Decimal{}}` on `"prices"` topic
- Reactive subscription — listens on `"watchlist:any"` PubSub, diffs current vs desired set on each `{:watchlist_changed, _}` and sends subscribe/unsubscribe frame deltas (no reconnect)
- Toggle via `:enable_price_stream` (default `true`)
- **Lifecycle (LON-67)**:
  - `terminate/2` sends `unsubscribe` frames + a WebSocket close frame before exit (best-effort) so app restart doesn't leave a zombie connection
  - `handle_disconnect/2` buckets reasons via `classify_reason/1` — persistent (`429`, `401/403` upgrade) → return `{:ok, state}` so the supervisor decides; transient (`{:remote, _}`, `502`, network) → `Process.sleep(backoff_ms(attempt))` then `:reconnect`, capped at 5 attempts
  - Telemetry: `[:long_or_short, :finnhub_stream, :disconnected | :reconnected]` with `reason_bucket` metadata

### `Tickers.Sources.IndicesPoller`

`lib/long_or_short/tickers/sources/indices_poller.ex` — GenServer, 30s poll (LON-75)

- Polls Finnhub `/quote` for DIA (DJIA), QQQ (NASDAQ-100), SPY (S&P 500)
- Broadcasts `{:index_tick, label, %{current, change_pct, prev_close, symbol, fetched_at}}` on `"indices"` topic
- Toggle via `:enable_indices_poller` (default `true`)

### `Tickers.Workers.FinnhubProfileSync`

`lib/long_or_short/tickers/workers/finnhub_profile_sync.ex` — Oban Cron, daily 05:00 UTC (LON-59, scope expanded LON-167)

- Syncs `Ticker` master fields from Finnhub `/stock/profile2`
- Field mapping: `name → company_name`, `exchange` (mapped to enum), `finnhubIndustry → industry`, `shareOutstanding × 1M → shares_outstanding/float_shares`
- **Symbol source (LON-167)**: union of `Tickers.Tracked.symbols/0` (manual watchlist ~29) and `Tickers.small_cap_symbols/0` (active IWM-derived universe ~1,917). Deduped, ~1,941 unique calls per cycle.
- Per-symbol 1.2s pause (60 req/min budget); cycle takes ~38 min; per-symbol failures logged, cycle continues

### `Tickers.SmallCapUniverseMembership`

`lib/long_or_short/tickers/small_cap_universe_membership.ex` — table `small_cap_universe_memberships` (LON-133)

The IWM-derived small-cap universe over which Tier 1 dilution analysis runs. One row per `(ticker_id, source)` (e.g. `:iwm`); `is_active = false` flags soft-deletions (delisting / rebalance).

#### Identity
`:unique_ticker_source` on `[:ticker_id, :source]`

#### Key actions
- `:upsert` — adds or reactivates a membership row
- `:deactivate` — soft delete (bulk-action friendly for rebalance sweeps)
- `:list_active` — returns active rows with `:ticker` loaded

#### Code interface (on `LongOrShort.Tickers` domain)
```elixir
upsert_small_cap_membership/1
list_active_small_cap_memberships/0
small_cap_symbols/0                    # convenience: active uppercased symbols
small_cap_ticker_ids/0                 # convenience: active ticker UUIDs
```

Refreshed weekly by `Tickers.Workers.IwmUniverseSync` (Mondays 06:00 UTC).

### `Tickers.DilutionProfile` (read-only aggregate)

`lib/long_or_short/tickers/dilution_profile.ex` — computed via `get_dilution_profile/1` (LON-116)

Per-ticker dilution overhang summary built from `FilingAnalysis` rows. Combines a 180-day window (configurable) for most filing types with full lifecycle tracking for ATM agreements (`ATM facility status`, `pending_s1`, `warrant_overhang`, `recent_reverse_split`, `insider_selling_post_filing`).

Shape: `%{ticker_id, overall_severity, overall_severity_reason, flags, active_atm, pending_s1, warrant_overhang, recent_reverse_split, insider_selling_post_filing, last_filing_at, data_completeness}` where `data_completeness ∈ [:full, :insufficient]`.

Consumed by `/feed`, dashboard cards, `/morning`, `/analyze` (LON-162) — live read, no snapshot column.

### `Tickers.Workers.IwmUniverseSync`

`lib/long_or_short/tickers/workers/iwm_universe_sync.ex` — Oban Cron, weekly Monday 06:00 UTC (LON-133)

Refreshes the small-cap universe from iShares' IWM holdings CSV. Adds new R2K members, deactivates dropped ones.

### `Tickers.WatchlistEvents` / `Tickers.WatchlistItem`

`watchlist_item.ex` + `watchlist_events.ex` — per-user dynamic watchlist (LON-90/92). Drives the `FinnhubStream` subscription set (LON-60) and any watchlist-scoped UI surface.

---

## `LongOrShort.Filings`

Dilution-relevant SEC filings (S-1, S-3, 424B*, 8-K, DEF 14A, Form 4) and their derived analyses. Parent epic: LON-106; current architecture from the two-tier dilution epic (LON-131).

### `Filing`

`lib/long_or_short/filings/filing.ex` — table `filings`

Per-filing metadata ingested from the SEC EDGAR `getcurrent` Atom feed.

#### Attributes
- `:id` — `uuid_v7`
- `:source` — atom, currently always `:sec_edgar`
- `:filing_type` — atom enum: `[:s1, :s1a, :s3, :s3a, :_424b1..b5, :_8k, :_13d, :_13g, :def14a, :form4]`
- `:filing_subtype` — string (e.g. `"8-K Item 3.02"`); populated for 8-K from summary parsing
- `:external_id` — SEC accession number
- `:filer_cik` — zero-padded 10-digit CIK
- `:filed_at` — utc_datetime, from Atom entry
- `:fetched_at` — utc_datetime, set on ingest
- `:url` — link to the SEC archive index

#### Identity
`:unique_filing` on `[:source, :external_id]`

#### Code interface
```elixir
ingest_filing/1                        # used by the feeder pipeline
ingest_filing_as_system/1              # wraps with SystemActor (LON-163)
get_filing/1
list_filings_for_ticker/1
get_filing_analysis_by_filing/1
```

### `FilingRaw`

`lib/long_or_short/filings/filing_raw.ex` — table `filings_raw`

Cold body storage for the filing — preserves the raw HTML/text fetched from SEC after `FilingBodyFetcher` lands it (LON-119). One row per `:filing_id`.

### `FilingAnalysis`

`lib/long_or_short/filings/filing_analysis.ex` — table `filing_analyses`

Two-tier dilution output (LON-131).

**Tier 1 attributes** — extracted by LLM via `Filings.extract_keywords/1`:
- `:dilution_type` — atom: `[:atm, :pipe, :convertible, :warrant, :registered_direct, :public_offering, :reverse_split, :other]`
- `:deal_size_usd`, `:share_count`, `:pricing_method`, `:pricing_discount_pct`, `:warrant_strike`, `:warrant_term_years`
- `:atm_remaining_shares`, `:atm_total_authorized_shares`
- `:shelf_total_authorized_usd`, `:shelf_remaining_usd`
- `:convertible_conversion_price`
- `:has_anti_dilution_clause`, `:has_death_spiral_convertible`, `:is_reverse_split_proxy`, `:reverse_split_ratio`
- `:summary` — LLM-written one-line description
- `:extracted_keywords` — raw structured map (preserved for downstream / debug)
- `:provider`, `:model`, `:raw_response`, `:analyzed_at`, `:extraction_quality`, `:rejected_reason`

**Tier 2 attributes** — added by deterministic `Filings.Scoring` after Tier 1:
- `:dilution_severity` — atom: `[:severe, :high, :medium, :low, :none]`
- `:matched_rules` — list of rule atoms that fired
- `:severity_reason` — human-readable explanation
- `:flags` — list of badges (`:death_spiral`, `:variable_pricing`, etc.)

#### Identity
`:unique_filing_analysis` on `[:filing_id]` — one row per filing, upsert-over

#### Key actions
- `:upsert_tier_1` — Tier 1 fields only (LON-134)
- `:upsert_tier_2` — Tier 2 fields only
- `:get_by_filing` — `get?: true`

### `InsiderTransaction`

`lib/long_or_short/filings/insider_transaction.ex` — table `insider_transactions`

Per-Form-4 insider trade rows (LON-118). Parsed directly from Form 4 XML by `Form4Parser` — no LLM. Linked to a `Filing` and the underlying `Ticker`. Cross-referenced against Tier 1 dilution events by `InsiderCrossReference` to surface "insiders sold N days after the S-3 filing" patterns.

### Filings ingestion pipeline

Mirror of the News pipeline shared via `LongOrShort.Sources.PipelineHelpers` (LON-142).

- **`Filings.Sources.SecEdgar`** — feeder GenServer polling SEC EDGAR `getcurrent` Atom per filing type (LON-111)
- **`Filings.Sources.Pipeline`** — wraps `PipelineHelpers` with a configurable `ingest_fun` sink
- **`Filings.SourceSupervisor`** — children from `:enabled_filing_sources` config
- **`Filings.SectionFilter`** — per-filing-type preprocessor that picks the dilution-relevant sections of the body before LLM (LON-113, deduped by header in LON-164)

### Workers

- `Filings.Workers.FilingBodyFetcher` — hourly :15 cron, batches ~100/cycle, sequential SEC fetches with rate-limit pacing (LON-119)
- `Filings.Workers.FilingAnalysisWorker` — every 15 min cron, Tier 1 over the small-cap universe; cost telemetry; Oban unique constraint blocks concurrent runs (LON-135 + LON-165)
- `Filings.Workers.FilingSeverityWorker` — every 5 min cron, Tier 2 background sweep promotes Tier-1-only rows to scored (LON-136)
- `Filings.Workers.Form4Worker` — hourly :30 cron, XML → InsiderTransaction (LON-118)
- `Filings.Workers.FilingAnalysisBackfillWorker` — on-demand bulk re-analysis (deferrable Phase 4, LON-137)
- `Filings.Workers.IngestHealthReporter` — daily 06:00 UTC, surfaces 24h aggregate of `FilingAnalysis` rejection rate + CIK drop counters (LON-161)

### `Filings.IngestHealth`

`lib/long_or_short/filings/ingest_health.ex` — public, named ETS counter for CIK-resolution drops (LON-161).

- Boot-time `init/0` creates `:filings_ingest_health` table; `attach_telemetry_handler/0` registers a handler on `[:long_or_short, :filings, :cik_drop]`
- Both `News.Sources.SecEdgar` and `Filings.Sources.SecEdgar` emit the event on every unmapped CIK with `%{source: :news | :filings, cik: cik}` metadata
- `read_and_reset_cik_drops/0` is the primary consumer (IngestHealthReporter); `peek_cik_drops/0` for debug
- Reason classification (`:dup_cik` / `:unmapped_cik` / `:other`) is deferred to LON-132

### Filings.Events / Filings.Severity / Filings.AtmLifecycle

- `Filings.Events` — PubSub wrapper for `"filings:analyses"` topic. Publishers: `Filings.Analyzer` (after Tier 1) and `FilingSeverityWorker` (after Tier 2). Subscribers: `FeedLive`, `DashboardLive`, `MorningBriefLive`, `AnalyzeLive` for live dilution badge refresh (LON-162).
- `Filings.SeverityRules` — deterministic rule catalogue. Tier 2 inputs the Tier-1 keywords + ticker context (shares_outstanding when available) and outputs severity + matched rules.
- `Filings.AtmLifecycle` — ATM facility state aggregator powering `DilutionProfile.active_atm`.

---

## `LongOrShort.MorningBrief`

Not an Ash domain (no resources) — three modules that produce the daily catalyst digest. Parent epic: LON-147.

- **`MorningBrief.Generator`** — synchronous orchestrator. Builds the prompt, calls Claude Sonnet 4.6 with the Anthropic web_search tool, persists the brief, broadcasts `{:morning_brief_generated, brief}` on the morning-brief topic, emits cost telemetry (`:morning_brief, :generated` / `:generation_failed`).
- **`MorningBrief.CronWorker`** — Oban Cron, fires every 15 min UTC; the worker itself filters down to the three ET wall-clock windows (premarket 05:00 / after-open 08:45 / mid-morning 10:15) on weekdays.
- **`MorningBrief.Prompts`** — prompt builder with persona injection from `TradingProfile`. Distinct prompts per window (premarket = "what's setting up overnight" vs after-open = "what's actually moving" vs mid-morning = "where's the day going").

The brief itself is persisted as an Ash resource on the parent `LongOrShort` ash_domains list — see `LongOrShortWeb.MorningBriefLive` for the consumer surface.

---

## `LongOrShort.News`

Articles ingested from external sources. The hot table — most queries hit it.

### `Article`

`lib/long_or_short/news/article.ex` — table `articles`

#### Per-ticker row duplication
When a source article tags multiple tickers, the feeder splits it into one row per ticker. Per-ticker timeline queries (`WHERE ticker_id = X ORDER BY published_at DESC`) become trivial. Trade-off: title text is duplicated, accepted for MVP.

#### Identity
`:unique_source_external_ticker` — `[:source, :external_id, :ticker_id]`

#### Attributes (summary)
- `:id` — `uuid_v7`
- `:source` — atom enum: `[:benzinga, :finnhub, :sec, :pr_newswire, :other]`
- `:external_id` — string, source's own id
- `:title`, `:summary`, `:url`, `:raw_category` — string
- `:sentiment` — atom enum: `[:positive, :negative, :neutral, :unknown]`
- `:content_hash` — SHA-256 of `title + summary`, populated by `ComputeContentHash` change. Used for "did the content actually change?" comparison (LON-54)
- `:published_at` — utc_datetime_usec, source's publish time
- `:fetched_at` — `create_timestamp`, **preserved on re-ingest**
- `:updated_at` — `update_timestamp`

#### Key actions

- **`:create`** (primary) — direct create with `:ticker_id` resolved
- **`:ingest`** — feeder workhorse; upsert on `:unique_source_external_ticker`. Takes `:symbol` argument, resolves to Ticker via `manage_relationship` (`on_lookup: :relate`, `on_no_match: {:create, :upsert_by_symbol}`)
- **`:by_ticker`** — read with required `:ticker_id`, sorted desc
- **`:recent`** — read with `:limit` arg (default 50), sorted desc
- **`:get_content_hash`** — lightweight read returning only `content_hash` for an identity, used by Pipeline for broadcast gating
- **`:recent_for_ticker`** — read with `:ticker_id` + `:since`
- **`:by_ticker_symbol`** — read with `:symbol`

#### Code interface (on `LongOrShort.News` domain)
```elixir
create_article/1
ingest_article/1                       # the feeder workhorse
get_article/1                          # get_by: [:id]
list_articles/0
list_articles_by_ticker/1              # args: [:ticker_id]
list_recent_articles/0
list_recent_articles_for_ticker/2      # args: [:ticker_id, :since]
list_articles_by_ticker_symbol/1       # args: [:symbol]
get_article_content_hash/3             # args: [:source, :external_id, :symbol]
destroy_article/1
```

#### Policies
- `bypass actor_attribute_equals(:system?, true)` — feeders bypass
- Admin full; authenticated traders read-only

### `News.Dedup`

`lib/long_or_short/news/dedup.ex` — pre-DB dedup GenServer

- ETS table `:news_seen` (public, named, set type)
- Key: `:crypto.hash(:sha256, "#{source}|#{external_id}|#{symbol}")`
- Value: insertion timestamp (millisecond)
- TTL: 24h (configurable via `:news_dedup_ttl_seconds`)
- Cleanup runs hourly via `Process.send_after`

API: `Dedup.check_and_mark/3`, `Dedup.seen?/3`

### `News.Events`

`lib/long_or_short/news/events.ex` — single source of truth for `"news:articles"` topic

```elixir
@topic "news:articles"

def subscribe, do: Phoenix.PubSub.subscribe(LongOrShort.PubSub, @topic)
def broadcast_new_article(article),
  do: Phoenix.PubSub.broadcast(LongOrShort.PubSub, @topic, {:new_article, article})
```

### `News.Sources.*`

Per-source feeders. Each is a `GenServer` implementing the `News.Source` behaviour and using `News.Sources.Pipeline` for the boilerplate.

- `News.Sources.Finnhub` — Finnhub `/company-news` polling (LON-44)
- `News.Sources.SecEdgar` — SEC EDGAR 8-K Atom feed (LON-45)
- `News.Sources.Dummy` — reference implementation
- `News.Sources.Pipeline` — shared lifecycle (poll → fetch → parse → dedup → upsert → content_hash gate → broadcast)
- `News.Sources.Backoff` — exponential backoff helper
- `News.SourceSupervisor` — owns the feeders; children loaded from `:enabled_news_sources` config

---

## `LongOrShort.Sources`

Per-source polling metadata, persisted across restarts.

### `SourceState`

`lib/long_or_short/sources/source_state.ex` — table `source_states`

#### Attributes
- `:source` — atom, **primary key**, enum `[:finnhub, :sec, :benzinga, :pr_newswire]`
- `:last_success_at` — utc_datetime_usec, nullable
- `:last_error` — string, nullable
- `:inserted_at`, `:updated_at`

#### Identity
`:unique_source` on `[:source]`

#### Actions
- **`:upsert`** — upsert on `:unique_source`; updates `[:last_success_at, :last_error, :updated_at]`
- **`:read`** — primary

#### Code interface (on `LongOrShort.Sources` domain)
```elixir
get_source_state/1                     # get_by: [:source]
upsert_source_state/1
```

#### Policies
SystemActor + admin bypass only — no trader read access (operational metadata).

Used by Finnhub (LON-55) to compute incremental fetch range, eliminating the "re-fetch last 3 days on every restart" problem.

---

## `LongOrShort.Analysis`

Results of LLM-driven analyses of news articles. Each analysis type is its own resource (no polymorphic JSON blobs) — Ash validations, queries, policies stay first-class. Currently ships only `NewsAnalysis` (LON-78 epic).

### `NewsAnalysis`

`lib/long_or_short/analysis/news_analysis.ex` — table `news_analyses`

#### Identity
`:unique_article` on `[:article_id]` — one row per article (upsert overwrites, no history rows kept)

#### Attributes (grouped)

**Card-level signals** (LLM-filled):
- `:catalyst_strength` — atom: `[:strong, :medium, :weak, :unknown]`
- `:catalyst_type` — atom (11 enums): `[:partnership, :ma, :fda, :earnings, :offering, :rfp, :contract_win, :guidance, :clinical, :regulatory, :other]`
- `:sentiment` — atom: `[:positive, :neutral, :negative]`
- `:verdict` — atom: `[:trade, :watch, :skip]`

**Repetition tracking** (LLM-filled):
- `:repetition_count` — integer, default 1
- `:repetition_summary` — string, optional (when count > 1)

**Phase 1 stubs** (analyzer writes explicit defaults):
- `:pump_fade_risk` — atom: `[:high, :medium, :low, :insufficient_data]`, default `:insufficient_data` (Phase 4 fills from price_reactions)
- `:strategy_match` — atom: `[:match, :partial, :skip]`, default `:partial` (Phase 2 fills from rule-based price/float/RVOL)
- `:strategy_match_reasons` — map, `%{}` in Phase 1
- `:rvol_at_analysis` — float, currently `nil`

**Card summary**:
- `:headline_takeaway` — string (one-line trader-voice)

**Detail view** (Markdown sections):
- `:detail_summary`, `:detail_positives`, `:detail_concerns`, `:detail_checklist`, `:detail_recommendation`

**Snapshot at analysis time** (frozen at create — what the trader saw when they clicked Analyze):
- `:price_at_analysis` — decimal
- `:float_shares_at_analysis` — integer

**LLM provenance** (cost tracking for LON-35):
- `:llm_provider` — atom: `[:claude, :mock, :other]`
- `:llm_model` — string
- `:input_tokens`, `:output_tokens` — integer

**Timestamps**:
- `:analyzed_at` — utc_datetime_usec, set by action
- `:created_at`, `:updated_at`

#### Relationships
`belongs_to :article, LongOrShort.News.Article` (allow_nil false, on_delete :restrict)

#### Actions
- **`:create`** — primary; sets `:analyzed_at` to UTC now
- **`:upsert`** — upsert on `:unique_article`; overwrites all signal fields and re-stamps `:analyzed_at`
- **`:get_by_article`** — read, `get?: true`, arg `:article_id`
- `:read`, `:destroy` — defaults

#### Code interface (on `LongOrShort.Analysis` domain)
```elixir
create_news_analysis/1
upsert_news_analysis/1
get_news_analysis/1                    # get_by: [:id]
get_news_analysis_by_article/1         # args: [:article_id], get?, not_found_error?: false
destroy_news_analysis/1
```

#### Policies
- SystemActor + admin bypass
- Authenticated traders read-only — writes go through `NewsAnalyzer` running as `SystemActor`

### `NewsAnalyzer` (orchestrator, not a resource)

`lib/long_or_short/analysis/news_analyzer.ex`

Sync entry point: `analyze(article, opts) :: {:ok, %NewsAnalysis{}} | {:error, term()}`

Required opts: `:actor` (the trader user whose `TradingProfile` shapes the prompt).

Optional opts: `:prior_window_days` (default 14), `:prior_limit` (default 10), `:model`, `:provider`.

Pipeline: load ticker → load TradingProfile → load prior same-ticker articles → build messages → AI call (Tool Use) → extract `record_news_analysis` tool call → validate enums → upsert `NewsAnalysis` (as `SystemActor`) → broadcast `{:news_analysis_ready, _}` on `"analysis:article:<id>"`.

Errors: `{:error, {:ai_call_failed, _}}`, `{:error, :no_tool_call}`, `{:error, {:invalid_enum, field, value}}`, `{:error, :no_trading_profile}`, plus pass-through Ash errors.

### `Analysis.Events`

`lib/long_or_short/analysis/events.ex` — PubSub topic wrapper

- `subscribe_for_article(article_id)` → subscribes to `"analysis:article:<id>"`
- `broadcast_analysis_ready(%NewsAnalysis{})` → broadcasts on the article's topic
- `subscribe/0` — legacy `"analysis_complete"` topic (no producer, removed in LON-83)

---

## `LongOrShort.Accounts`

Authentication, user roles, and per-user trader configuration.

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
- Confirmation: `confirm_on_create? true`, sender `Accounts.User.Senders.SendNewUserConfirmationEmail`
- Password reset wired up
- Tokens: `Accounts.Token` resource (table `tokens`) — JTI store, expiry, revocation

#### Key actions
- `:register_with_password`, `:sign_in_with_password`, `:sign_in_with_token`, `:get_by_subject`
- `:change_password`, `:request_password_reset_token`, `:reset_password_with_token`
- `:get_by_email`

#### Relationships
- `has_one :trading_profile` → `TradingProfile`

### `TradingProfile`

`lib/long_or_short/accounts/trading_profile.ex` — table `trading_profiles` (LON-88)

One profile per user, enforced by `:unique_user` identity. Drives prompt personalization in `AI.Prompts.NewsAnalysis` and (Phase 2) rule-based `:strategy_match`.

#### Attributes — core (apply to all styles)
- `:trading_style` — atom: `[:momentum_day, :large_cap_day, :swing, :position, :options]`
- `:time_horizon` — atom: `[:intraday, :multi_day, :multi_week, :multi_month]`
- `:market_cap_focuses` — `{:array, :atom}`, items in `[:micro, :small, :mid, :large]`
- `:catalyst_preferences` — `{:array, :atom}`, 14 items including `:partnership`, `:fda`, `:analyst`, `:macro`, `:sector`, etc.
- `:notes` — string, free-form addendum

#### Attributes — style-specific (nullable, populated when relevant)
- `:price_min`, `:price_max` — decimal (typically momentum/small-cap)
- `:float_max` — integer (typically momentum/small-cap)

More niche fields (RVOL thresholds, pattern preferences) belong in a separate `MomentumStrategyConfig` resource — not added until Phase 2 rule-based work needs them.

#### Identity
`:unique_user` on `[:user_id]`

#### Actions
- `:create`, `:upsert` (on `:unique_user`), `:get_by_user`, `:read`, `:destroy`

#### Code interface (on `LongOrShort.Accounts` domain)
```elixir
create_trading_profile/1
upsert_trading_profile/1
get_trading_profile_by_user/1          # args: [:user_id], get?, not_found_error?: false
destroy_trading_profile/1
```

#### Policies
- SystemActor + admin bypass
- Trader can `:read` and `:create`/`:update` (LON-15 will tighten to "only own profile" once auth hardens; Phase 1 single-user makes it moot)

This deviates from `NewsAnalysis` (where writes go through SystemActor only) because TradingProfile is **user-owned configuration**, not system output.

### `SystemActor`

`lib/long_or_short/accounts/system_actor.ex` — non-Ash plain struct

```elixir
%SystemActor{system?: true, name: "system"}
```

Used by feeders, workers, and the analyzer's persistence write to bypass policies. **MVP shortcut** — anyone can construct one. LON-15 tracks the migration.

---

## `LongOrShort.Sec`

Not a domain (no Ash resources) — a pair of modules that maintain the SEC CIK ↔ ticker link on `Ticker.cik`.

- **`Sec.CikMapper`** — pure sync module. Downloads `https://www.sec.gov/files/company_tickers.json` and upserts each entry into `Ticker` (`:cik`, `:symbol`, `:company_name`). Skips duplicate-CIK entries (preferred shares, ADRs).
- **`Sec.CikSyncWorker`** — Oban Cron worker (LON-57), daily 04:00 UTC, max 3 retries. Replaces the earlier boot-time `Task` approach.

---

## `LongOrShort.Indices`

Not a domain (no Ash resources) — only a PubSub wrapper.

- **`Indices.Events`** — `subscribe/0` and `broadcast/2` for the `"indices"` topic. Called by `Tickers.Sources.IndicesPoller` (producer) and `DashboardLive` (consumer).

---

## Domain registration

Domains registered in `config :long_or_short, :ash_domains`:

```elixir
[
  LongOrShort.Accounts,
  LongOrShort.News,
  LongOrShort.Tickers,
  LongOrShort.Sources,
  LongOrShort.Analysis,
  LongOrShort.Filings,
  LongOrShort.Settings
]
```

Plain modules (not Ash domains):
- `LongOrShort.Sec` — CIK mapping (`CikMapper` + `CikSyncWorker`)
- `LongOrShort.Indices` — `Indices.Events` PubSub wrapper
- `LongOrShort.MorningBrief` — Generator + CronWorker + Prompts (the brief is persisted via a different domain)
- `LongOrShort.AI` — provider behaviour + facade; implementations under `AI.Providers.*` (currently `Claude`, `Qwen`, `MockProvider`)
