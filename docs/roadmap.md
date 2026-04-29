# Roadmap

> ⚠️ This is a snapshot. Linear is the source of truth: https://linear.app/long-or-short/

## Current sprint focus

**Theme**: Round out free data sources, then ship the AI analysis layer on richer text.

| Order | Ticket | Title |
|-------|--------|-------|
| 1 | **LON-45** | SEC EDGAR RSS source — 8-K filings |
| 2 | **LON-22 epic** | AI Analysis Layer (MVP) — Repetition Detection |

LON-22 is broken into sub-tickets that can run partly in parallel:

| Ticket | Title | Depends on |
|--------|-------|------------|
| LON-23 | AI Provider behaviour + facade module | — |
| LON-24 | Claude provider implementation (`Req`) | LON-23 |
| LON-25 | RepetitionAnalysis Ash resource + Analysis domain | — (parallel) |
| LON-26 | Repetition tool schema + prompt template | — (parallel) |
| LON-27 | RepetitionAnalyzer business logic | LON-24, LON-25, LON-26 |
| LON-28 | PubSub subscription worker (auto-trigger) | LON-27 |
| LON-29 | Display analysis results in `/feed` | LON-28 |

## Up next (after LON-22)

- **LON-35 epic** — AI cost optimization
  - LON-37: Rule-based pre-filter (Stage 1, no AI)
  - LON-38: Anthropic prompt caching
  - LON-39: Structured output (JSON)
  - LON-41: Haiku → Sonnet cascade
  - LON-40: Embedding-based repetition detection
  - LON-42: Per-ticker price reaction cache
  - LON-43: Batch API for non-realtime work
- **LON-30 epic** — Articles storage strategy (raw payload separation, partitioning)
- **LON-36** — DB-backed watchlist (replaces `:finnhub_watch_symbols` config hack)

## Backlog flags

- **LON-15** — Migrate `SystemActor` bypass to `private_action?()` pattern. Required before any external API exposure.
- **LON-21** — Parse error observability + DLQ. Defer until real sources show real parse failures.
