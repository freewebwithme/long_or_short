# Architecture

## High-level data flow

```
External APIs                Ingestion Pipeline                       Subscribers
─────────────                ─────────────────                        ───────────
Finnhub (free tier)          News.Sources.Finnhub  ──┐
SEC EDGAR RSS (planned)  ──→ News.Sources.SecEdgar ──┤
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
                                          └──────────────────────┘     └─────────────┘
                                                                       (Analysis worker
                                                                        planned, LON-22)
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

Sources never crash on transient errors — they return `{:error, reason, new_state}` and Pipeline applies exponential backoff.

### Shared pipeline logic (`News.Sources.Pipeline`)
The boilerplate every source needs lives here:

- Polling scheduling via `Process.send_after`
- Pre-DB dedup via ETS (`News.Dedup`)
- Calling `News.ingest_article/2` with `SystemActor`
- PubSub broadcast on successful ingest
- Exponential backoff on `fetch_news` errors

Feeders are ~6 lines of GenServer boilerplate plus three callback implementations. See `lib/long_or_short/news/sources/dummy.ex` for the smallest reference implementation.

### Per-item resilience
A bad parse on one raw item, or an ingest failure on one article, does **not** abort the batch. Each item is logged individually. Only `fetch_news/1` returning `{:error, ...}` triggers backoff — that's the signal of a source-wide problem.

## Deduplication (two layers)

Articles are deduplicated at two levels:

| Layer | Storage | TTL | Scope | Purpose |
|-------|---------|-----|-------|---------|
| **`News.Dedup`** | ETS (`:news_seen`) | 24h | `(source, external_id, ticker)` SHA-256 | Cheap pre-DB skip — avoid round-trip on already-seen articles |
| **`Article` upsert** | Postgres unique index | Permanent | `(source, external_id, ticker_id)` | DB-level guarantee, queryable, auditable |

Pre-DB ETS dedup is an optimization, not a correctness mechanism — the DB upsert is the source of truth.

## PubSub event contract

A single topic carries all news events. The contract is wrapped by `LongOrShort.News.Events` so topic strings never appear elsewhere.

| Topic | Payload | Publisher | Subscriber |
|-------|---------|-----------|------------|
| `news:articles` | `{:new_article, %Article{}}` | News.Sources.Pipeline | LiveView, Analysis (planned) |

Publishers call `Events.broadcast_new_article(article)`. Subscribers call `Events.subscribe()`.

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
