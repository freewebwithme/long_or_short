# Long or Short

A real-time news analysis tool for small-cap momentum traders.

When a small-cap stock pumps on a news catalyst, traders have minutes — sometimes seconds — to decide whether to enter, hold, or skip. The hard part isn't reading the headline; it's the context: *Is this the fourth partnership announcement this quarter? Has this ticker historically spiked and faded after similar news? Does it even fit my strategy filters?*

Long or Short collapses that 5-10 minute manual research loop into a single AI-generated card, delivered to a live feed the moment the news breaks.

## How it works

```
External sources                Pipeline                       UI
─────────────────               ─────────────                  ─────────
Finnhub (free tier)             News.Source behaviour          Phoenix
SEC EDGAR RSS         ──→       (poll, dedup, ingest)   ──→    LiveView
                                       │                       feed (/feed)
                                       ▼
                                Phoenix PubSub
                                       │
                                       ▼
                                AI Analysis Layer
                                (repetition check,
                                 price pattern,
                                 strategy filter)
```

Each news source is its own GenServer implementing a common `News.Source` behaviour — polling cadence, dedup via ETS, and PubSub broadcast are handled by shared `Pipeline` helpers. Adding a new source is essentially "implement three callbacks." Articles flow into Postgres through Ash resources, then a parallel analysis pipeline calls Claude to score the news against the trader's playbook before pushing the result to the LiveView feed.

## What the AI actually does

Three checks, run on every article that passes the strategy pre-filter:

1. **Repetition detection** — Has this company released similar news before? A fourth partnership announcement carries less weight than the first.
2. **Price pattern** — How has this ticker historically reacted to similar catalysts? "Spike-then-fade" patterns get flagged so the trader doesn't chase.
3. **Strategy filter** — Price range ($2–$10), float (under 50M), relative volume (200%+), catalyst presence. Hard cutoffs that disqualify before any AI cost is spent.

The output is a verdict — `LONG` / `SHORT` / `SKIP` — with the reasoning attached.

## Tech stack

- **Elixir / Phoenix LiveView** — chosen for the natural fit between OTP supervision and a fault-tolerant ingestion pipeline. LiveView removes the entire frontend framework layer for a project that's fundamentally a real-time feed.
- **Ash Framework 3.x + AshPostgres** — declarative resources, code interfaces, and policy-based authorization. The data model gets typed end-to-end without hand-rolling Ecto changesets.
- **PostgreSQL** — primary store. Hot path (per-ticker timeline) is backed by a composite index on `(ticker_id, published_at)`.
- **Phoenix PubSub** — single source of truth for inter-module communication. Topics are wrapped in `LongOrShort.News.Events` so the contract lives in one place.
- **Anthropic Claude API** — the analysis brain. Provider abstraction is in place from day one so swapping in another LLM is a small change.

## Project structure

```
lib/long_or_short/
├── tickers/             # Ticker master data (symbol, float, last_price, ...)
│   └── ticker.ex
├── news/                # Article ingestion + storage
│   ├── article.ex
│   ├── events.ex        # PubSub wrapper — single place for topic strings
│   ├── dedup.ex         # ETS-based pre-DB dedup
│   ├── source.ex        # Behaviour all feeders implement
│   ├── pipeline.ex      # Shared polling/backoff/broadcast helpers
│   ├── source_supervisor.ex
│   └── sources/
│       └── dummy.ex     # Reference implementation of News.Source
├── accounts/
│   └── system_actor.ex  # Bypass actor for background feeders
└── application.ex
```

The split between domains (`Tickers`, `News`) is deliberate — articles reference tickers by FK, and the feeder upserts a minimal Ticker on the fly when a new symbol shows up. Price enrichment happens out-of-band.

## Running locally

Requires Elixir 1.16+, Erlang/OTP 26+, and PostgreSQL.

```bash
# Install deps and set up DB
mix setup

# Start the server (Dummy source begins emitting articles immediately)
mix phx.server
```

Visit `http://localhost:4000/feed` (sign-in required — Ash Authentication is wired up via magic link).

For real news sources, set:

```bash
export FINNHUB_API_KEY="your_key_here"
```

## Event contract

The pipeline communicates over a single PubSub topic. Adding a subscriber is one call; the message format is fixed across the codebase.

| Topic            | Payload                            | Publisher       | Subscriber                |
|------------------|------------------------------------|-----------------|---------------------------|
| `news:articles`  | `{:new_article, %Article{}}`       | News sources    | LiveView, Analysis worker |

All access goes through `LongOrShort.News.Events` — no string topic literals scattered through the codebase.

## Why I'm building this

I trade small-cap momentum on the side. Every morning I run through the same routine — gap scanner, news scan, then ten minutes of context gathering on each ticker. Most of that context-gathering is mechanical: "have I seen this story before?", "did this ticker pump and dump last time?", "does it even fit my filters?"

It's exactly the kind of work an LLM should be doing for me. So I'm building it.
