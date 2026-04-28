# Roadmap

> ⚠️ This is a snapshot. Linear is the source of truth: https://linear.app/long-or-short/

## Current sprint focus

**Theme**: Eliminating redundant API calls and broadcast noise across server restarts (LON-52 epic).

| Ticket | Title | Depends on |
|--------|-------|------------|
| **LON-53** | SourceState resource — persist per-source polling metadata | — |
| **LON-54** | Pipeline: content_hash-based broadcast gate | LON-53 |
| **LON-55** | Finnhub: use SourceState for incremental fetch | LON-53 |

## Up next

- **LON-45** — SEC EDGAR RSS source (free, no API key)
- **LON-22 epic** — AI Analysis layer (the core value prop)
  - LON-23: AI Provider behaviour + facade
  - LON-25: RepetitionAnalysis Ash resource
  - LON-26: Repetition tool schema + prompt template
  - LON-24: Claude provider implementation
  - LON-27, 28, 29: integration with Pipeline

## Backlog flags

- **LON-15** — Migrate `SystemActor` bypass to `private_action?()` pattern. Required before any external API exposure.
- **LON-36** — DB-backed watchlist (replaces the `:finnhub_watch_symbols` config hack)
