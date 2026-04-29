# Design Decisions

This document captures the *why* behind significant choices. New decisions should be appended chronologically with the date.

---

## 2026-04 — `News.Source` behaviour with shared Pipeline (LON-18)

**Decision**: All news feeders implement a 3-callback behaviour. Polling, dedup, ingestion, broadcast, and backoff live in a separate `Pipeline` module called from each feeder's GenServer.

**Rationale**: Adding a new source should be small. Current implementations (Dummy, Finnhub) are essentially "implement 3 callbacks + 6 lines of GenServer boilerplate." This made the Finnhub source (LON-44) trivial to add after Dummy was working.

**Trade-off**: Pipeline reserves `:retry_count` in the GenServer state map. Feeders must not collide. Documented in `pipeline.ex` moduledoc.

---

## 2026-04 — Per-ticker row duplication for multi-ticker articles

**Decision**: When a source article tags multiple tickers, the feeder writes one Article row per ticker (not a join table).

**Rationale**: The hot path query is "give me articles for ticker X, newest first." A join table would require an additional join. Per-ticker rows make the index `(ticker_id, published_at)` directly serve the query.

**Trade-off**: Title/summary text duplicated. For small-cap news (typically 1-3 tickers per article), this is acceptable storage cost vs query speed.

---

## 2026-04 — `SystemActor` as MVP auth bypass (LON-15 to migrate)

**Decision**: Feeders and background jobs use `%SystemActor{system?: true}` as the actor, with resources declaring `bypass actor_attribute_equals(:system?, true)` in their policies.

**Rationale**: Single-developer codebase, no external API exposure. Building a proper "private action" system (`public? false` + `private_action?()`) before validating the data flow worked would have been premature.

**Known risk**: Anyone can construct a `SystemActor`. If even one user-controlled code path reaches actor construction, all policies are bypassed. LON-15 tracks the migration before any of these change:
- External API exposure (AshJsonApi/GraphQL)
- Multi-developer codebase
- User-controlled data path that touches actor construction

---

## 2026-04 — Hot path index auto-managed by AshPostgres (LON-31)

**Decision**: Don't declare `custom_indexes` for `(ticker_id, published_at)`. Use the FK index AshPostgres auto-generates from the `belongs_to :ticker` relationship.

**Rationale**: First attempt declared an explicit `custom_indexes` block, which conflicted with the auto-generated FK index, producing two identical indexes. Postgres B-tree handles backward scans natively, so DESC ordering doesn't need to be explicit on the index either.

**Documentation**: `article.ex` `postgres do` block has a comment noting the auto-generated index, so future migration runs aren't accidentally surprised.

---

## 2026-04 — Magic link strategy removed (LON-47)

**Decision**: Remove magic link authentication. Use password-only.

**Rationale**: AshAuthentication generated a `magic_sign_in_route` and `auto_confirm_actions [:sign_in_with_magic_link]` reference, but no `magic_link` strategy was actually configured. This caused compile/route errors. Adding the missing strategy would require email sender setup. For a single-user MVP, password auth is sufficient.

---

## 2026-04 — Counter on `/feed` is "events received", not "unique articles"

**Decision**: The `@article_count` assign in `FeedLive` reflects how many `{:new_article, _}` PubSub events were received in the session, not how many unique articles are in the stream.

**Rationale**: Re-ingested articles update the stream in-place via `stream_insert` (same DOM id), but the counter still increments. We could track a set of seen ids to count only unique articles, but the simpler fix was relabeling: "X updates received" is honest about what the number represents.

---

## 2026-04 — Broadcast gate: content_hash comparison, not insert/update flag (LON-52, LON-54)

**Decision**: Pipeline broadcasts only when the article's `content_hash` changes (or the article is new). Implementation: read existing `content_hash` before `ingest_article`, compare to result.

**Rationale**: The natural-feeling answer is "broadcast if INSERT, not on UPDATE." But Ash's upsert API doesn't expose whether the operation resulted in an INSERT vs UPDATE — both look identical to the caller. Time-based heuristics (e.g. "fetched_at is fresh") were considered but felt brittle.

`content_hash` directly answers the question we actually care about: **did the content meaningfully change?** Ignored re-ingests of identical content silently. Updates with new title/summary trigger a re-broadcast.

**Cost**: One extra read per ingest. Acceptable — the read is on a unique index.

**Implication**: ETS Dedup is no longer a "broadcast gate" — its sole role is now "skip the DB round-trip on already-seen articles." The DB upsert + content_hash comparison is the source of truth for broadcast decisions.

---

## 2026-04 — Persistent per-source polling state (LON-52, LON-53, LON-55)

**Decision**: Add `LongOrShort.Sources.SourceState` Ash resource keyed on `:source` to track `last_success_at` per feeder. Feeders read this on startup to compute their fetch range, eliminating the "re-fetch last 3 days on every restart" anti-pattern.

**Options considered**:
- GenServer state only (current) — fine until you restart
- Oban job state — overkill for "remember a timestamp"
- File system — breaks on container redeploy
- DB key-value resource — chosen

**Rationale**: This is a cross-source concern. As source count grows (Finnhub, SEC, eventually Benzinga, PR Newswire, Twitter), restart cost grows linearly with redundant API calls. Each call against a paid tier source is real money. Solving it once at the Pipeline level is cheaper than adding a per-source patch later.

---

## 2026-04 — Watchlist via config (temporary, LON-36 to migrate)

**Decision**: Finnhub source reads its watch list from `:finnhub_watch_symbols` application config (currently `~w(BTBD AAPL TSLA NVDA AMD)`).

**Rationale**: The DB-backed watchlist (LON-36) requires a UI for users to add/remove tickers. We weren't ready to build that when LON-44 landed, but we needed *some* way to validate Finnhub polling end-to-end.

**Documented in code**: `finnhub.ex` moduledoc has an explicit "TEMPORARY — replace with DB watchlist in LON-36" callout with the exact replacement code.

---

## 2026-04 — Test determinism: no `Process.sleep` (LON-51)

**Decision**: Banned `Process.sleep` from test code. TTL-related tests inject expired timestamps directly into ETS. PubSub-related tests use `assert_receive` with explicit timeouts.

**Rationale**: Sleep makes tests slow *and* flaky under load (CI is the worst case). The deterministic alternatives are not harder to write — they're often clearer about what the test actually depends on.

---

## 2026-04 — Source order before AI: SEC EDGAR before LON-22

**Decision**: Implement LON-45 (SEC EDGAR RSS) before starting the LON-22 AI analysis epic, despite the original sprint plan pointing the other way.

**Rationale**: Finnhub `company-news` returns short summaries (1–2 sentences) — enough for repetition detection and basic categorization, but thin for deeper analysis (deal size, dilution, risk factors). SEC 8-K filings are first-party disclosures with substantive content. Layering AI on top of richer source text produces meaningfully better verdicts than running it on Finnhub summaries alone.

**Trade-off**: AI layer ships one ticket later. Acceptable — the analysis is the product's core value, and shipping it on weak data would create a misleading first impression.

**What we explicitly rejected**: Full-text scraping of the URLs Finnhub returns (Reuters, Benzinga, etc.). Per-site scrapers, paywall handling, and the legal grey area aren't worth the maintenance load. SEC + Finnhub summary covers most of the gap.

---

## 2026-04 — Anthropic API: `Req` directly, no SDK

**Decision**: Call the Anthropic API via `Req` from inside our own `LongOrShort.AI.Provider` behaviour. Do not depend on `anthropix` or any other community SDK.

**Rationale**:
- The Anthropic API surface we use is small (`POST /v1/messages` plus a few headers). The wrapping value of an SDK is low.
- Advanced features on the LON-35 cost-optimization roadmap — prompt caching, Haiku/Sonnet cascade, Batch API — need precise control over headers, request shape, and response parsing. SDKs tend to lag behind these.
- `anthropix` last shipped in mid-2025 with a small maintainer footprint. Pinning core analysis to a stagnant dependency is a risk we don't need to take.
- We already plan a `LongOrShort.AI.Provider` behaviour (LON-23). That's our abstraction; an SDK underneath would just be a wrapper-of-a-wrapper.

**Implication**: Each new Anthropic feature we adopt (caching, batching, etc.) is a deliberate code change in our provider, not a dependency upgrade.
