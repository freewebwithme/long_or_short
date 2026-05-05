# Architecture

> Last updated: 2026-05-05

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

```
LongOrShort.Application (one_for_one)
├── LongOrShortWeb.Telemetry
├── LongOrShort.Repo                          # PostgreSQL connection pool
├── DNSCluster                                # Multi-node clustering
├── Oban (via AshOban)                        # Cron scheduler
│   ├── 04:00 UTC → Sec.CikSyncWorker         # CIK↔ticker refresh (LON-57)
│   └── 05:00 UTC → Tickers.Workers.FinnhubProfileSync  # Profile enrichment (LON-59)
├── Phoenix.PubSub (LongOrShort.PubSub)       # Pub/sub backbone
├── LongOrShort.News.Dedup                    # ETS-based pre-DB dedup
├── LongOrShort.News.SourceSupervisor         # Owns all News.Source feeders
│   └── (children loaded from :enabled_news_sources config)
├── Task.Supervisor                           # Reserved for analysis fan-out
│   (LongOrShort.Analysis.TaskSupervisor)
├── LongOrShortWeb.Endpoint                   # Phoenix HTTP/WebSocket
├── AshAuthentication.Supervisor              # Token cleanup, etc.
├── Tickers.Sources.FinnhubStream             # if :enable_price_stream (default true)
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
| `analysis_complete` | (legacy, no producer) | — | Removed in LON-83 |
| `prices` | `{:price_tick, symbol, %Decimal{}}` | `Tickers.Sources.FinnhubStream` | `FeedLive`, `DashboardLive` (PriceLabel hook) |
| `indices` | `{:index_tick, label, payload}` | `Tickers.Sources.IndicesPoller` | `DashboardLive` |

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
- **watchlist_card** — symbols from `priv/watchlist.txt` with live prices
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
