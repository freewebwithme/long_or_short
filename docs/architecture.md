# Architecture

## High-level data flow

```
External APIs                Ingestion Pipeline                       Subscribers
─────────────                ─────────────────                        ───────────
Finnhub (company-news)       News.Sources.Finnhub  ──┐
SEC EDGAR RSS (LON-45)   ──→ News.Sources.SecEdgar ──┤
Future sources               News.Sources.* ─────────┤
                                                     │
                                                     ▼
                                          ┌──────────────────────┐
                                          │  Pipeline.run_poll   │
                                          │  (fetch → parse →    │
                                          │   dedup → ingest →   │
                                          │   broadcast)         │
                                          └──────────┬───────────┘
                                                     │
                                                     ▼
                                          ┌──────────────────────┐
                                          │ Article (Ash upsert) │
                                          └──────────┬───────────┘
                                                     │
                                                     ▼
                                          ┌──────────────────────┐
                                          │   Phoenix PubSub     │     ┌─────────────┐
                                          │  "news:articles"     │  ─→ │  FeedLive   │
                                          │  {:new_article, _}   │     │  /feed page │
                                          │                      │  ─→ │  Analysis   │
                                          │                      │     │  worker     │
                                          └──────────────────────┘     │  (LON-22)   │
                                                                       └──────┬──────┘
                                                                              │
                                                                              ▼
                                                                    LongOrShort.AI
                                                                    (Provider behaviour
                                                                     + Req → Anthropic)
```

## Application supervision tree

```
LongOrShort.Application (one_for_one)
├── LongOrShortWeb.Telemetry
├── LongOrShort.Repo                          # PostgreSQL connection pool
├── DNSCluster                                # Multi-node clustering
├── Oban (via AshOban)                        # Job scheduler (currently unused, present for future)
├── Phoenix.PubSub (LongOrShort.PubSub)       # Pub/sub backbone
├── LongOrShort.News.Dedup                    # ETS-based pre-DB dedup
├── LongOrShort.News.SourceSupervisor         # Owns all News.Source feeders
│   └── (children loaded from :enabled_news_sources config)
├── LongOrShortWeb.Endpoint                   # Phoenix HTTP/WebSocket
└── AshAuthentication.Supervisor              # Token cleanup, etc.
```

## News ingestion pipeline

The ingestion lifecycle is split into two layers:

### Per-source feeder (`News.Sources.*`)
Each source is its own `GenServer` that implements the `News.Source` behaviour:

- Owns polling state (cursors, retry count)
- Knows how to talk to its API (`fetch_news/1`)
- Knows how to map its API response to Article attrs (`parse_response/1`)
- Declares its base polling interval (`poll_interval_ms/0`)
- Declares its `source_name/0` atom for SourceState lookup (LON-55)

Sources never crash on transient errors — they return `{:error, reason, new_state}` and Pipeline applies exponential backoff.

### Shared pipeline logic (`News.Sources.Pipeline`)
The boilerplate every source needs lives here:

- Polling scheduling via `Process.send_after`
- Pre-DB dedup via ETS (`News.Dedup`)
- Calling `News.ingest_article/2` with `SystemActor`
- `content_hash` comparison to gate broadcasts (LON-54)
- `SourceState` updates (`last_success_at`, `last_error`) on each cycle (LON-55)
- PubSub broadcast on genuine new/changed articles
- Exponential backoff on `fetch_news` errors

Feeders are ~6 lines of GenServer boilerplate plus three callback implementations. See `lib/long_or_short/news/sources/dummy.ex` for the smallest reference implementation.

### Per-item resilience
A bad parse on one raw item, or an ingest failure on one article, does **not** abort the batch. Each item is logged individually. Only `fetch_news/1` returning `{:error, ...}` triggers backoff — that's the signal of a source-wide problem.

## Deduplication and broadcast gating

Two layers cooperate:

| Layer | Storage | TTL | Scope | Purpose |
|-------|---------|-----|-------|---------|
| **`News.Dedup`** | ETS (`:news_seen`) | 24h | `(source, external_id, ticker)` SHA-256 | Cheap pre-DB skip — avoid round-trip on already-seen articles within a session |
| **`Article` upsert** | Postgres unique index | Permanent | `(source, external_id, ticker_id)` | DB-level guarantee, queryable, auditable |
| **`content_hash` compare** | Postgres unique index | Permanent | `(source, external_id, ticker_id)` | Decides whether to broadcast — only when content actually changed |

ETS Dedup is an in-session optimization; the DB upsert + `content_hash` is the source of truth for both correctness (no duplicate rows) and broadcast behavior (no duplicate fan-out).

## PubSub event contract

A single topic carries all news events. The contract is wrapped by `LongOrShort.News.Events` so topic strings never appear elsewhere.

| Topic | Payload | Publisher | Subscriber |
|-------|---------|-----------|------------|
| `news:articles` | `{:new_article, %Article{}}` | `News.Sources.Pipeline` (only on new/changed content) | `FeedLive`, Analysis worker (LON-28) |

Publishers call `Events.broadcast_new_article(article)`. Subscribers call `Events.subscribe()`.

## AI analysis layer (LON-22)

Planned. Subscribes to `news:articles`, decides whether to invoke an AI provider, persists results.

- `LongOrShort.AI` — facade module
- `LongOrShort.AI.Provider` — behaviour (LON-23). One implementation per LLM.
- `LongOrShort.AI.Providers.Claude` — Anthropic via `Req` (LON-24). No SDK; we control headers, body, parsing directly.
- `LongOrShort.Analysis.RepetitionAnalysis` — Ash resource for analysis output (LON-25)
- `LongOrShort.Analysis.AnalysisWorker` — PubSub subscriber that triggers analysis (LON-28)

## Authorization model

Two actor types coexist:

- **`%User{}`** — human-facing. Created via `AshAuthentication`. Has `:role` (`:admin` or `:trader`).
- **`%SystemActor{system?: true}`** — non-human trusted callers (feeders, jobs). Bypasses all policies.

Resources use `bypass actor_attribute_equals(:system?, true)` to recognize the system actor. This is a known MVP shortcut — see LON-15 for the planned migration to `private_action?()` pattern.

## Web layer

LiveView is the only frontend — no separate JS framework. The single feed page subscribes to `news:articles` on mount and uses `stream_insert` for efficient DOM updates.

| Route | Module | Purpose |
|-------|--------|---------|
| `/feed` | `LongOrShortWeb.FeedLive` | Real-time article stream |
| `/sign-in`, `/register` | AshAuthentication | Auth |
