# Architecture

> Last updated: 2026-05-15

## High-level data flows

Three concurrent pipelines run side-by-side:

### 1. News ingestion → article stream

```
External APIs                Ingestion Pipeline                       Subscribers
─────────────                ─────────────────                        ───────────
Finnhub /company-news        News.Sources.Finnhub  ──┐
SEC EDGAR Atom 8-K       ──→ News.Sources.SecEdgar──┤
Future sources               News.Sources.* ────────┤
                                                    │
                                                    ▼
                                         ┌──────────────────────┐
                                         │  News.Sources.       │
                                         │     Pipeline         │
                                         │  fetch → parse →     │
                                         │  ETS dedup → upsert →│
                                         │  content_hash gate → │
                                         │  broadcast           │
                                         └──────────┬───────────┘
                                                    │
                                                    ▼
                                         ┌──────────────────────┐
                                         │ News.Article         │     ┌──────────────┐
                                         │ (Ash upsert)         │ ──→ │ FeedLive     │
                                         │ + PubSub broadcast   │ ──→ │ DashboardLive│
                                         │   "news:articles"    │     └──────────────┘
                                         └──────────────────────┘
```

### 2. Live market data (separate from news)

```
Finnhub WebSocket trades    Tickers.Sources.FinnhubStream    "prices" topic
                            (per-trade tick)              ─→ {:price_tick, sym, decimal}
                                                                       │
                                                                       ▼
                                                              FeedLive / DashboardLive
                                                              (PriceLabel hook updates DOM)

Finnhub /quote (DIA,QQQ,SPY) Tickers.Sources.IndicesPoller   "indices" topic
                            (30s poll)                    ─→ {:index_tick, label, payload}
                                                                       │
                                                                       ▼
                                                                DashboardLive
```

### 3. User-triggered analysis

```
User clicks Analyze on /feed
        │
        ▼
┌────────────────────────────┐
│ Analysis.NewsAnalyzer      │
│  1. load Article.ticker    │
│  2. load TradingProfile    │
│  3. load prior articles    │
│     (14d window, cap 10)   │
│  4. Prompts.NewsAnalysis   │
│  5. AI.call (Tool Use)     │
│  6. validate enums         │
│  7. upsert NewsAnalysis    │
│  8. broadcast              │
└────────────┬───────────────┘
             │
             ▼
"analysis:article:<id>" topic    ─→  FeedLive (article-scoped subscriber)
{:news_analysis_ready, %NewsAnalysis{}}
```

The analyzer is **synchronous** — the LiveView awaits the result and renders inline. There is no async PubSub-driven worker.

## Application supervision tree

Before children start, `Application.start/2` runs two side effects (LON-161):
1. `Filings.IngestHealth.init/0` — creates the named ETS counter for CIK drops
2. `Filings.IngestHealth.attach_telemetry_handler/0` — registers the increment handler on `[:long_or_short, :filings, :cik_drop]`

So the very first drop after boot is counted.

```
LongOrShort.Application (one_for_one)
├── LongOrShortWeb.Telemetry                  # Telemetry supervisor — children:
│   ├── :telemetry_poller (10s period)
│   └── Telemetry.Metrics.ConsoleReporter     # dev-only, filtered to :long_or_short events (LON-168/169)
├── LongOrShort.Repo                          # PostgreSQL connection pool
├── LongOrShort.Settings.Loader               # boot-time hydration of admin-tunable settings (LON-125)
├── DNSCluster
├── Oban (via AshOban)                        # Cron + queue scheduler
│   ├── 04:00 UTC → Sec.CikSyncWorker                      # CIK ↔ ticker (LON-57)
│   ├── 05:00 UTC → Tickers.Workers.FinnhubProfileSync     # Profile + shares_outstanding (LON-59/167)
│   ├── 06:00 UTC → Filings.Workers.IngestHealthReporter   # 24h Tier 1 health summary (LON-161)
│   ├── 06:00 UTC Mon → Tickers.Workers.IwmUniverseSync    # Small-cap universe refresh (LON-133)
│   ├── :15 hourly → Filings.Workers.FilingBodyFetcher     # SEC body fetch (LON-119)
│   ├── :30 hourly → Filings.Workers.Form4Worker           # Insider trade XML (LON-118)
│   ├── */15 min   → Filings.Workers.FilingAnalysisWorker  # Tier 1 dilution extract (LON-135 + LON-165 unique)
│   ├── */5  min   → Filings.Workers.FilingSeverityWorker  # Tier 2 background sweep (LON-136)
│   ├── 0,30 hourly → News.MorningBoundaryPollWorker        # Catalyst-window force-poll (LON-152)
│   └── */15 min   → MorningBrief.CronWorker               # Three daily ET windows (LON-149/151)
├── Phoenix.PubSub (LongOrShort.PubSub)
├── LongOrShort.News.Dedup                    # ETS pre-DB dedup
├── LongOrShort.News.SourceSupervisor         # Children from :enabled_news_sources (Alpaca / Finnhub / SecEdgar / Dummy)
├── LongOrShort.Filings.SourceSupervisor      # Children from :enabled_filing_sources (SecEdgar)
├── Task.Supervisor (LongOrShort.Analysis.TaskSupervisor)
├── LongOrShortWeb.Endpoint                   # Phoenix HTTP/WebSocket
├── AshAuthentication.Supervisor
├── Tickers.Sources.FinnhubStream             # if :enable_price_stream (default true) — graceful shutdown via LON-67
└── Tickers.Sources.IndicesPoller             # if :enable_indices_poller (default true)
```

## News ingestion pipeline

Two layers:

### Per-source feeder (`News.Sources.*`)
Each source is a `GenServer` that implements the `News.Source` behaviour:

- Owns polling state (cursors, retry count)
- `fetch_news/1` — talk to API
- `parse_response/1` — map API response → Article attrs
- `poll_interval_ms/0` — base polling interval
- `source_name/0` — atom for `SourceState` lookup (LON-55)

Sources never crash on transient errors — they return `{:error, reason, new_state}` and Pipeline applies exponential backoff.

### Shared pipeline logic (`News.Sources.Pipeline`)
Boilerplate every source needs:

- Polling scheduling via `Process.send_after`
- Pre-DB dedup via ETS (`News.Dedup`)
- Calling `News.ingest_article/2` with `SystemActor`
- `content_hash` comparison to gate broadcasts (LON-54)
- `SourceState` updates (`last_success_at`, `last_error`) on each cycle (LON-55) — restart-safe incremental fetch
- PubSub broadcast on genuine new/changed articles
- Exponential backoff on `fetch_news` errors

Feeders are ~6 lines of GenServer boilerplate plus three callback implementations. See `lib/long_or_short/news/sources/dummy.ex` for the smallest reference.

### Per-item resilience
A bad parse or an ingest failure on one item does **not** abort the batch. Each item is logged individually. Only `fetch_news/1` returning `{:error, ...}` triggers backoff — that's the signal of a source-wide problem.

## Filings ingestion pipeline (Tier 1 dilution)

Mirrors the News pipeline (same `Sources.PipelineHelpers`, same `:retry_count` / backoff contract) but routes parsed filings into `Filings.ingest_filing_as_system/1`. Tier 1 dilution extraction (`FilingAnalysisWorker`, LON-135) runs as a separate Oban cron over the small-cap universe.

### Consolidated backpressure policy (LON-161)

Single reference for every rate-limit / backoff knob in the Tier 1 path. Update this table when any layer's policy changes — don't sprinkle the constants across module docstrings.

| Layer | Limit | Pause / backoff | Failure mode |
|-------|-------|-----------------|--------------|
| **SEC EDGAR Atom fetch** (`Filings.Sources.SecEdgar`) | 10 req/s SEC ceiling | `@request_spacing_ms 150` (~6.7 req/s) between filing-type requests; per-cycle exponential backoff via `News.Sources.Backoff` on `fetch_filings/1` errors | Partial: logged + per-type errors carried forward; All-fail: source-wide retry via `Backoff.next_interval/2` |
| **FilingRaw body fetch** (`FilingBodyFetcher` Oban worker) | SEC 10 req/s shared with feeder | Sequential per-cycle with the same SEC-ceiling buffer; per-job `max_attempts: 3` | `:no_primary_document` (Form 4, by design) → drop; transient HTTP → Oban retry; permanent → mark failed in source-state log |
| **Tier 1 LLM call** (`FilingAnalysisWorker` → `AI.call/3`) | Anthropic per-model ITPM/RPM (Sonnet 4.6 / Haiku 4.5) | `@default_per_item_pause_ms 200` between items; `AI.call/3` retry-with-backoff on `{:rate_limited, n}` (max 2 retries, honors `retry-after` header — LON-163); `unique: [period: :infinity, states: [:available, :scheduled, :executing]]` blocks concurrent Tier 1 batches (LON-165) | After all retries: persist `:rejected` row with `rejected_reason: {:rate_limited, _}`; counted in daily summary (LON-161) |

### Drop / rejection observability (LON-161)

Two ephemeral failure modes that don't surface as `FilingAnalysis` rows are tracked separately:

- **CIK drops** — both `News.Sources.SecEdgar` and `Filings.Sources.SecEdgar` resolve filer CIK → local ticker via `Tickers.get_ticker_by_cik/1`. Unmapped CIKs (mutual funds, dup-CIK multi-class shares pending LON-132, OTC tickers absent from `company_tickers.json`) emit `[:long_or_short, :filings, :cik_drop]` telemetry. A boot-attached handler accumulates per-source counts in ETS; `IngestHealthReporter` reads + resets them on the 06:00 UTC cron.

  Reason classification (`:dup_cik` "expected" vs `:unmapped_cik` "bootstrap not yet run" vs `:other`) is deferred — current code only knows the boolean "unmapped." LON-132 will persist the CIK provenance needed to distinguish these.

- **Tier 1 rejections** — `FilingAnalysis` rows with `extraction_quality = :rejected` are persisted on validation failure, LLM unusability, or exhausted rate-limit retries. The daily reporter aggregates the last-24h window from `filing_analyses` directly (no in-memory counter needed) and logs `rejection_rate_pct` + top-5 `rejected_reason` values.

Both go through `IngestHealthReporter`'s single summary line at 06:00 UTC and a `[:long_or_short, :ingest_health, :daily_summary]` telemetry event for any downstream dashboards.

## Deduplication and broadcast gating

| Layer | Storage | TTL | Scope | Purpose |
|-------|---------|-----|-------|---------|
| **`News.Dedup`** | ETS (`:news_seen`) | 24h | `(source, external_id, ticker)` SHA-256 | Cheap pre-DB skip — avoid round-trip on already-seen articles within a session |
| **`Article` upsert** | Postgres unique index | Permanent | `(source, external_id, ticker_id)` | DB-level guarantee, queryable, auditable |
| **`content_hash` compare** | Postgres column | Permanent | per-Article | Decides whether to broadcast — only when content actually changed |

ETS Dedup is an in-session optimization; the DB upsert + `content_hash` comparison is the source of truth for both correctness (no duplicate rows) and broadcast behavior (no duplicate fan-out).

## PubSub event contract

Topics are wrapped by domain-specific Events modules so topic strings never appear elsewhere.

| Topic | Payload | Publisher | Subscribers |
|-------|---------|-----------|-------------|
| `news:articles` | `{:new_article, %Article{}}` | `News.Sources.Pipeline` (only on new/changed content) | `FeedLive`, `DashboardLive` |
| `analysis:article:<id>` | `{:news_analysis_ready, %NewsAnalysis{}}` | `Analysis.NewsAnalyzer` (after upsert) | `FeedLive` (article-scoped) |
| `filings:analyses` | `{:new_filing_analysis, %FilingAnalysis{}}` | `Filings.Analyzer` (Tier 1) + `FilingSeverityWorker` (Tier 2) | `FeedLive`, `DashboardLive`, `MorningBriefLive`, `AnalyzeLive` — drives live dilution badge refresh (LON-162) |
| `prices` | `{:price_tick, symbol, %Decimal{}}` | `Tickers.Sources.FinnhubStream` | `FeedLive`, `DashboardLive` (PriceLabel hook) |
| `indices` | `{:index_tick, label, payload}` | `Tickers.Sources.IndicesPoller` | `DashboardLive` |
| `watchlist:any` | `{:watchlist_changed, user_id}` | `Tickers.WatchlistEvents` on `WatchlistItem` mutations | `FinnhubStream` (recomputes subscription set + sends frame deltas) |
| (morning brief topic) | `{:morning_brief_generated, brief}` | `MorningBrief.Generator` after persist | `MorningBriefLive` |

Publishers go through:
- `LongOrShort.News.Events.broadcast_new_article/1`
- `LongOrShort.Analysis.Events.broadcast_analysis_ready/1`
- `LongOrShort.Indices.Events.broadcast/2`
- (Price stream broadcasts directly to `"prices"` — single producer, simple shape)

Subscribers go through the matching `subscribe/0` or `subscribe_for_article/1`.

## AI / Analysis layer

The pivot from RepetitionAnalysis (LON-22 epic, retired in LON-80) to NewsAnalysis (LON-78 epic) consolidated all card signals into a single resource.

- **`LongOrShort.AI`** — facade. `call(messages, tools, opts)` resolves the configured provider and delegates.
- **`LongOrShort.AI.Provider`** — behaviour (LON-23). One implementation per LLM.
- **`LongOrShort.AI.Providers.Claude`** — Anthropic via `Req` (LON-24). Tool Use mode (not JSON parsing). System message extracted from messages list and routed to Anthropic's top-level `system` parameter.
- **`LongOrShort.AI.Tools.NewsAnalysis`** — tool spec (`record_news_analysis`). Schema with 11 required + 1 optional fields, enum constraints for catalyst_strength / catalyst_type / sentiment / verdict.
- **`LongOrShort.AI.Prompts.NewsAnalysis`** — prompt builder. Takes the article, prior same-ticker articles, and a `TradingProfile`. Persona branching on `:trading_style` (momentum_day / large_cap_day / swing / position / options).
- **`LongOrShort.Analysis.NewsAnalysis`** — Ash resource. One row per article (upsert-over via `:unique_article` identity).
- **`LongOrShort.Analysis.NewsAnalyzer`** — sync orchestrator: `analyze(article, actor: user) -> {:ok, %NewsAnalysis{}} | {:error, _}`. Caller awaits.
- **`LongOrShort.Analysis.Events`** — PubSub topic wrapper.

Phase 1 stubs (`:pump_fade_risk`, `:strategy_match`, `:rvol_at_analysis`) are explicitly written by the analyzer — they don't come from the LLM. Phase 2 (rule-based `:strategy_match` from price/float/RVOL) and Phase 4 (`:pump_fade_risk` from a price-reactions history table) update the same row through separate code paths.

### Filings analysis (two-tier dilution, LON-131)

Mirrors the same AI facade but splits work explicitly between LLM and rules:

- **`LongOrShort.Filings.Analyzer.extract_keywords/1`** (Tier 1) — LLM call. Cheap model (Haiku 4.5 / configured Qwen fallback). Outputs structured deal terms (`dilution_type`, `deal_size_usd`, `pricing_method`, ATM/shelf state, etc.) plus an `extraction_quality` field. Cost-controlled: section preprocessor (`SectionFilter`) cuts input tokens by header de-dup (LON-164); `AI.call/3` retries on 429 with backoff (LON-163); `FilingAnalysisWorker` is Oban-unique to prevent concurrent burst (LON-165).
- **`LongOrShort.Filings.Analyzer.score_severity/1`** (Tier 2) — pure deterministic rules over the Tier 1 output + ticker context. No LLM. Outputs `dilution_severity`, `matched_rules`, `severity_reason`, `flags`. Runs as a background sweep via `FilingSeverityWorker` (LON-136).

This split is a key architectural decision (LON-160): severity must be auditable + free, while extraction is the expensive but parallelizable LLM work. Tier 2 needs no UI gating — it just happens after Tier 1 lands and broadcasts on `"filings:analyses"`.

## Authorization model

Two actor types coexist:

- **`%User{}`** — human-facing. Created via `AshAuthentication`. Has `:role` (`:admin` | `:trader`).
- **`%SystemActor{system?: true}`** — non-human trusted callers (feeders, jobs, the analyzer's persistence write). Bypasses all policies.

Resources use `bypass actor_attribute_equals(:system?, true)` to recognize the system actor. **MVP shortcut** — anyone can construct a `SystemActor`. LON-15 tracks the migration to `private_action?()` before any external API exposure.

`TradingProfile` is the exception — traders may create/upsert their own profile (it's user-owned config, not system output). LON-15 will tighten this to "only their own profile" once auth hardens.

## Web layer

LiveView is the only frontend — no separate JS framework. Tailwind + daisyUI for styling.

| Route | Module | Auth | Purpose |
|-------|--------|------|---------|
| `/` | `DashboardLive` | required | Indices + watchlist + ticker search + condensed news |
| `/feed` | `FeedLive` | required | Real-time article stream + price/float filter + Analyze |
| `/sign-in`, `/register`, `/reset` | AshAuthentication.Phoenix | public (`live_no_user`) | Auth UI (DaisyUI overrides) |
| `/auth/*` | `AuthController` | public | Auth strategy callbacks |
| `/sign-out` | `AuthController` | public | Sign out |
| `/auth/user/confirm_new_user` | confirm_route | public | Email confirmation |
| `/dev/dashboard`, `/dev/mailbox`, `/oban`, `/admin` | dev-only | dev | Telemetry / mailer / Oban / AshAdmin |

### Dashboard composition (`/`)

`DashboardLive` renders six widgets (helper functions, not LiveComponents):

- **indices_card** — DJIA / NASDAQ-100 / S&P 500 tiles with live %change
- **watchlist_card** — symbols from `priv/tracked_tickers.txt` with live prices (LON-94 will rewire to the per-user DB watchlist)
- **search_card** — debounced ticker search with autocomplete
- **ticker_info_card** — selected ticker details + live last_price
- **ticker_news_card** — articles for selected ticker
- **global_news_card** — recent articles across all tickers

### Feed page (`/feed`)

- LiveView stream (`articles`) — initial 30, prepend on `news:articles`
- Filter UI: price min/max (Decimal), float max in millions — 300ms debounce
- Per-card Analyze button (LON-83 wiring in progress; current placeholder shows flash)
- Live last_price updates per card via `PriceLabel` hook on `phx:price_tick`

### Shared front-end

- `LongOrShortWeb.Format` — `price/1`, `relative_time/1`, `shares/1`, `pct/1`
- `PriceLabel` colocated JS hook — DOM update on `phx:price_tick` events
- `article_card` component — used by both Dashboard news widgets and Feed stream
- Nav active state via `LiveUserAuth.assign_current_path` on_mount hook
