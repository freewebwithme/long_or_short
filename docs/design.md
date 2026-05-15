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

---

## 2026-04 — Anthropic Tool Use over JSON-mode parsing (LON-24, LON-26)

**Decision**: The Claude provider drives structured output via Anthropic's Tool Use feature, not by asking the model to emit JSON in the message body and parsing it.

**Rationale**:
- Tool Use enforces the input schema at the API level. Wrong types or missing required fields fail at the provider, not in our deserializer.
- Enums are validated twice — once by the tool schema, once by our `to_enum_atom/3` mapper using `String.to_existing_atom/1`. Anything off the allowed list fails fast with a clear `{:invalid_enum, field, value}` error instead of an opaque cast failure later.
- Our prompts include an explicit closing instruction ("Always respond by calling the `record_news_analysis` tool. Do not respond in plain text."), so a missing tool call is a real anomaly and triggers `{:error, :no_tool_call}` rather than silent text-only output.

**Trade-off**: Anthropic-specific. A future provider (OpenAI, local Llama, etc.) needs an equivalent function-calling shape, or a parallel tool-call adapter. The provider behaviour's `tool_call` type is generic enough to absorb that.

---

## 2026-04 — File-backed ingestion universe over config or DB (LON-64, renamed LON-91)

**Decision**: The single source of truth for "which symbols does the system poll" is `priv/tracked_tickers.txt` — one symbol per line, `#` comments allowed. A pure module (`Tickers.Tracked`) reads it on demand.

**Rationale**:
- The earlier `:finnhub_watch_symbols` config approach required a code release to add a symbol — friction during MVP exploration.
- A DB-backed watchlist resource would solve that, but pulls in a settings UI, multi-user scoping, and authorization questions. Premature for solo use at the time.
- A file in `priv/` is editable from any text editor, survives restarts, deployable as a config artifact, and lets every consumer (`FinnhubStream`, `IndicesPoller`, `FinnhubProfileSync`, `DashboardLive`) call `Tracked.symbols/0` without coordinating reads.
- Tests override via `:tracked_tickers_override` env (list of symbols).

**LON-91 note**: The file and module were renamed from `watchlist` → `tracked_tickers` / `Tracked` to clarify that this is the **ingestion universe**, not the trader's personal watchlist. The per-user dynamic watchlist ships as a separate DB resource (LON-90 / LON-92).

---

## 2026-04 — Live last_price via Finnhub WebSocket trade ticks (LON-60)

**Decision**: A dedicated `Tickers.Sources.FinnhubStream` GenServer holds a WebSocket connection to Finnhub's trade-tick feed, subscribes to every watchlist symbol, and per tick (a) updates `Ticker.last_price` via `:update_ticker_price`, (b) broadcasts `{:price_tick, symbol, %Decimal{}}` on the `"prices"` topic.

**Rationale**:
- Polling `/quote` for every ticker every few seconds quickly exceeds Finnhub's 60 req/min budget once the watchlist grows.
- `Ticker.last_price` doubles as a queryable field for filters (`/feed` price filter) and the live display value, so writing it from one place avoids divergence.
- A separate process keeps the WebSocket lifecycle (reconnect, backoff, key-rotation) isolated from the rest of the supervision tree.

**Trade-off**: Free-tier limit is 50 subscriptions; a larger watchlist needs sharding or paid tier. Acceptable for MVP.

**Toggle**: `:enable_price_stream` (default `true`) gates the child in `application.ex` — disabled in tests and dev environments without API keys.

---

## 2026-04 — Daily Finnhub profile2 enrichment via Oban Cron (LON-59)

**Decision**: A daily Oban Cron job (`Tickers.Workers.FinnhubProfileSync`, 05:00 UTC) calls Finnhub `/stock/profile2` for each watchlist symbol and upserts the master fields (`company_name`, `exchange`, `industry`, `shares_outstanding`, `float_shares`).

**Rationale**:
- These fields change rarely (corporate action cadence — IPOs, splits, listings). A daily refresh is enough.
- Per-symbol 1.2-second pause keeps us inside the 60 req/min budget without dipping into the live ticker stream's allowance.
- Oban gives us per-job logs in the DB, automatic retry on transient errors, and a UI (`/oban` in dev) to see history.

**Trade-off**: First boot of a new symbol shows incomplete master data until the next 05:00 UTC run. Acceptable for MVP — the analyzer falls back to whatever is present.

**Float-shares accuracy caveat**: Finnhub's `shareOutstanding` is total shares, not free float. We currently store it into `:float_shares` as a proxy. LON-68 tracks the migration to a real free-float source (FMP).

---

## 2026-05 — CIK sync moved from boot Task to Oban Cron (LON-57)

**Decision**: SEC's `company_tickers.json` import (10K+ rows into `Ticker.cik`) runs as `Sec.CikSyncWorker` on Oban Cron (04:00 UTC daily, max 3 retries) instead of as a fire-and-forget `Task` from the application supervisor.

**Rationale**:
- The boot-time `Task` punished local restarts with a multi-second download + DB churn. Worse, transient SEC outages on boot meant CIK mapping was simply absent until the next deploy — no retry, no visibility.
- Oban gives us idempotent retry, per-run history queryable via `oban_jobs`, and a clean separation between "the app is running" and "the daily data refresh ran."
- 04:00 UTC keeps the heavier job ahead of the lighter Finnhub profile sync at 05:00 UTC.

**Trade-off**: First-time setup needs to either let the cron run once or invoke `Sec.CikMapper.sync()` manually in IEx. Acceptable — bootstrap is rare.

---

## 2026-05 — Phoenix scaffold strip + dashboard-first foundation (LON-70, LON-72)

**Decision**: Replace the generated Phoenix `PageController` and welcome page with a custom `DashboardLive` at `/`, behind authentication. Build a design-token shell (Tailwind + daisyUI) before adding feature widgets.

**Rationale**:
- Every authenticated user lands on something useful (live indices, watchlist, news) instead of the Phoenix splash page.
- Establishing nav, header, theme toggle, and design tokens up front means the subsequent widget tickets (LON-73 through LON-77) only add content — no styling drift between widgets.
- LiveView session is now scoped via `ash_authentication_live_session :authenticated_routes` with on-mount hooks for auth + current-path tracking.

**Trade-off**: A design system commitment. Theme choices (color tokens, daisyUI theme) are locked in early. Acceptable — switching later is a CSS pass, not a structural change.

---

## 2026-05 — Per-user prompt personalization via TradingProfile (LON-88)

**Decision**: The system prompt for `NewsAnalyzer` is built from a per-user `TradingProfile` (in the `Accounts` domain) — not hardcoded for "small-cap momentum day trader." The profile drives persona branching across five trading styles.

**Rationale**:
- LON-88 market research showed that on news-active retail platforms (Stocktwits-style), day traders are ~15%, swing 29%, long-term 48%. Hardcoding the small-cap scalper persona would alienate the larger audience the moment the app went past solo use.
- A `:trading_style` enum (`:momentum_day | :large_cap_day | :swing | :position | :options`) lets the prompt builder select the right behavioral guidance (scalp/fade vs continuation vs IV implications, etc.).
- Style-specific fields (`:price_min/max`, `:float_max`) are nullable. The prompt renders only what's present, so each style sees a focused profile instead of a one-size-fits-all questionnaire.
- Catalyst preferences are first-class — the LLM is told which catalyst types this trader cares about and frames its `:verdict` accordingly.

**Trade-off**: One profile per user, enforced by `:unique_user`. Multi-strategy traders (someone who day trades small-caps Mon-Tue and swings large-caps Wed-Fri) need to pick a primary. Acceptable for MVP — a `MomentumStrategyConfig`-style child resource is the planned escape hatch.

**Policy deviation**: Traders can write their own profile (it's user-owned config). Other Analysis-domain resources are SystemActor-write only. Documented in `TradingProfile` moduledoc.

---

## 2026-05 — RepetitionAnalysis pivot to NewsAnalysis (LON-78 epic, LON-79/80/81/82/89)

**Decision**: Retire the original `RepetitionAnalysis` resource + `RepetitionAnalyzer` module (LON-22 epic) and replace them with a single richer `NewsAnalysis` resource + `NewsAnalyzer` orchestrator. One row per article, upsert-over (no history rows).

**Rationale**:
- Repetition counting alone produced cards that were "correct but boring" — the trader still had to read the article to decide. Useful as a signal, insufficient as a verdict.
- Separating repetition from sentiment, catalyst type, and verdict into four sibling resources would have multiplied query joins for every card render. One row per article serves the hot path directly.
- Upsert-over (no history) is intentional. We're optimizing for "show the latest analysis" not "audit the model's evolution." If we need history later, a separate `news_analysis_history` table can be added without changing the read path.
- The pivot also reframed the analyzer as **synchronous + user-triggered**, not an async PubSub-driven worker. A trader clicks Analyze, awaits a few seconds, sees the result inline — no background fan-out, no batch invalidation, no "analysis pending" intermediate states.

**Migration sequence**:
- LON-79: build new `MomentumAnalysis` Ash resource alongside the old one
- LON-81: tool spec + prompt builder
- LON-82: business logic
- LON-89: rename `MomentumAnalysis` → `NewsAnalysis` (broader naming for non-momentum styles enabled by LON-88)
- LON-80: retire `RepetitionAnalysis` + `RepetitionAnalyzer`

**Trade-off**: No history of past LLM outputs per article. If we want to A/B prompts or detect model drift, we need to add a separate audit table. Deferred — `:llm_provider`, `:llm_model`, `:input_tokens`, `:output_tokens` give us enough to spot drift via aggregate queries.

---

## 2026-05 — Phase 1 stubs for `:pump_fade_risk` and `:strategy_match`

**Decision**: The analyzer writes `:pump_fade_risk = :insufficient_data` and `:strategy_match = :partial` explicitly on every row. The tool schema **does not expose** these fields to the LLM at all.

**Rationale**:
- Asking the LLM to guess pump/fade risk from a headline alone produces hallucinated confidence. The real signal lives in a future `price_reactions` history table (Phase 4).
- `:strategy_match` belongs to deterministic rules over price band, float, and RVOL (Phase 2) — not LLM judgment.
- Writing the stubs explicitly (not relying on Ash `default`s) is defense in depth: even if a future change adds these fields to the tool schema by mistake, the analyzer still overwrites them with the stub value until the real implementation lands.
- The card UI still has to render these fields. Visual treatment for `:insufficient_data` and `:partial` is part of the card design, not a "missing data" state.

**Trade-off**: Two card slots show placeholder values until Phase 2/4 land. Acceptable — better an honest stub than a fake confidence reading.

---

## 2026-05 — Two-tier dilution analysis: LLM extract + deterministic score (LON-131, LON-160)

**Decision**: Filings analysis splits the LLM and rule-based work into two explicit tiers.

- **Tier 1** (`Filings.Analyzer.extract_keywords/1`) — cheap LLM call that outputs structured deal terms. Runs proactively over the small-cap universe every 15 min.
- **Tier 2** (`Filings.Analyzer.score_severity/1`) — pure deterministic rules over Tier 1 output. Outputs `:dilution_severity`, matched rule list, reason text. No LLM.

**Rationale**:
- Severity must be **auditable and reproducible** for trader trust ("why is this severe?"). A rule catalog with a `matched_rules` list answers that; an LLM verdict doesn't.
- Tier 1's variable cost is the LLM tokens. Tier 2 is free, so there's no reason to gate it on user action. Background sweep promotes Tier-1-only rows to scored within ~5 min.
- The split also lets Tier 2 evolve independently — adding a new rule doesn't require re-running Tier 1 on existing rows.

**Trade-off**: One filing produces two write paths (Tier 1 upsert → Tier 2 upsert). The `FilingAnalysis` resource handles this via `upsert_tier_1` and `upsert_tier_2` actions that touch disjoint field sets. Idempotent.

**Originally framed** as "Tier 2 = Sonnet" (more powerful LLM judgment) in the LON-131 spec, but LON-160 review caught the conflict with the parent epic LON-106's "severity is code rules, not LLM" decision. Resolved by retracting the Tier 2 = LLM framing.

---

## 2026-05 — Live dilution profile read + PubSub-driven UI re-render (LON-160 Option C, LON-162)

**Decision**: Every dilution-displaying surface (`/feed`, `/`, `/morning`, `/analyze`) reads live from `Tickers.get_dilution_profile/1` and re-renders on Tier 2 promotion via the `"filings:analyses"` PubSub topic. The legacy `dilution_*_at_analysis` snapshot columns on `NewsAnalysis` get deprecated for read (writer side unchanged).

**Rationale**:
- Snapshots are stale by design — a filing analyzed at 9am with severity `:medium` may upgrade to `:severe` at 9:15 when Tier 2 finds an undisclosed warrant overhang. A trader still looking at the card at 9:20 must see the new severity, not the snapshot.
- LiveView streams + PubSub make this cheap. Subscribe once per LiveView, re-stream_insert on broadcast.
- Snapshot columns stay populated for audit purposes (what severity was shown at the time of analysis) — just not used for read.

**Trade-off**: Every dilution-displaying LiveView holds a per-ticker profile cache in socket assigns (`%{ticker_id => profile}` + `articles_by_id` for stream re-insertion). The `DilutionProfiles` helper module consolidates the load/subscribe/refresh pattern.

---

## 2026-05-15 — LLM rate-limit handling: facade-level retry + Oban-unique batch isolation (LON-163, LON-165)

**Decision**: Two layers of rate-limit defense in the Tier 1 pipeline.

1. **Per-call retry-with-backoff** in `AI.call/3` (LON-163): on `{:rate_limited, retry_after}`, sleep for `retry_after` (or fallback linear backoff with jitter), retry up to 2 times. Opt-out via `retry: false`.
2. **Batch-level Oban unique** on `FilingAnalysisWorker` (LON-165): `unique: [period: :infinity, states: [:available, :scheduled, :executing]]`. New cron firings while a previous batch is still running are silently deduped — effective Tier 1 concurrency becomes 1 regardless of queue concurrency.

**Rationale**:
- Naive unconditional retry on 429 turns a transient throttle into an abuse trigger (observed in the same-day FinnhubStream WebSocket case, LON-67).
- Two parallel Tier 1 batches × ~20 items each × Anthropic's per-minute token budget = 20% rejection rate even with retry enabled. The fix isn't longer sleeps; it's preventing the burst.
- `unique` on `:available | :scheduled | :executing` is the cleanest Oban primitive — no custom locks, no advisory keys.

**Trade-off**: Tier 1 backlog accumulation is now visible — if filing volume exceeds worker throughput at the configured pause, work piles up instead of running in parallel. That's a feature, not a bug: surfaces capacity issues as queue depth instead of burning calls in burst-and-fail mode.

---

## 2026-05-15 — Tier 1 ingest health: ephemeral ETS counter + DB aggregate via single daily reporter (LON-161)

**Decision**: Operational visibility for the dilution pipeline ships as one daily Oban cron + one ETS counter + per-event telemetry.

- **`Filings.IngestHealth`** module owns a named ETS counter incremented via a boot-attached telemetry handler. Receives `[:long_or_short, :filings, :cik_drop]` from both `News.Sources.SecEdgar` and `Filings.Sources.SecEdgar`. Read-and-reset via `:ets.take/2` (atomic).
- **`Filings.Workers.IngestHealthReporter`** runs daily at 06:00 UTC. Pulls 24h `filing_analyses` aggregates from the DB (rejection rate + top-5 rejected reasons) and drains the CIK drop counters. Logs a one-line summary + emits `[:long_or_short, :ingest_health, :daily_summary]` telemetry.

**Rationale**:
- CIK drops don't produce `FilingAnalysis` rows — they're silent skips at the resolver. Without a counter, we can't measure "how many catalysts did we miss because of unmapped CIKs."
- `FilingAnalysis` already persists `extraction_quality` + `rejected_reason` per row. Aggregating those at report time avoids a second in-memory counter.
- Reporter ordering: DB query FIRST, then drain counter. If the DB read raises, Oban retries with the counter preserved instead of silently zeroing.

**Trade-off**: Drop counter is ephemeral — lost on app restart. Acceptable for "24h drop rate" visibility; if long-term accounting is needed later, persist drops to a table. Reason classification (`:dup_cik` vs `:unmapped_cik` vs `:other`) is deferred to LON-132 because the current resolver only knows the boolean "unmapped" — distinguishing requires CIK provenance.

---

## 2026-05-15 — FinnhubStream lifecycle: bucket by reason, don't reconnect on 429 (LON-67)

**Decision**: WebSocket `handle_disconnect/2` classifies the disconnect reason into `:transient` or `:persistent` via `classify_reason/1`.

- `:persistent` (`429`, `401/403` upgrade) → return `{:ok, state}`. **Stop reconnecting.** The supervisor decides whether to restart the process.
- `:transient` (`{:remote, _}`, `:tcp_closed`, `502`, network blips) → `Process.sleep(backoff_ms(attempt))` then `:reconnect`. Cap at 5 attempts before giving up.

**Rationale**:
- Pre-LON-67 code unconditionally returned `{:reconnect, state}`. On 2026-05-15, this caused an observed tight `429` loop: upstream 502 → unconditional reconnect → Finnhub abuse-policy fires → 429 → unconditional reconnect → more 429s.
- Reconnecting on 429 *is* what triggers the abuse-policy throttling. The correct response to "you are rate-limited" is "stop," not "back off and try the same thing again."
- `terminate/2` sends `unsubscribe` frames + a WS close frame on the way out, shortening the "two concurrent connections" window on app restart from "OS TCP timeout" to milliseconds.

**Trade-off**: Bucket classification is an empirical lookup table — we add new reasons as we observe them in production. The default for unknown reasons is `:transient` (try to recover), which is the safer default.

---

## 2026-05-15 — Telemetry sink: LiveDashboard full registry + dev ConsoleReporter on filtered subset (LON-168, LON-169)

**Decision**: `LongOrShortWeb.Telemetry.metrics/0` registers all 65 metrics across our 28 custom events. `live_dashboard "/dashboard"` consumes the full list. `Telemetry.Metrics.ConsoleReporter` (dev only) consumes a filtered subset via `console_metrics/0` — only `[:long_or_short, ...]` events with `:repo` excluded.

**Rationale**:
- Telemetry data with no consumer is dead emit work. The dashboard exists; wiring it up is cheap.
- ConsoleReporter prints every emit of every registered metric. With Phoenix/Repo/VM defaults in the registry, that's dozens of lines per second per page load — drowns the dev IEx.
- Filtering at the reporter (not the registry) keeps the LiveDashboard tabs populated while keeping the console signal-to-noise high.

**Trade-off**: Adding a new `:telemetry.execute/3` site silently lands in the console firehose unless it's deliberately added to `metrics/0`. The `LongOrShortWeb.TelemetryTest` regression test catches "you added an emit site, you forgot the metric registration" by failing if any custom event isn't in `metrics/0`.

---

## 2026-05-15 — Free-tier ingest, paid-data unlock thesis

**Decision**: Stay on free-tier news data (Finnhub `/company-news`, Alpaca news, SEC EDGAR) through Phase 4 even though the in-product news surfaces don't directly drive trading decisions yet.

**Rationale (validated by trader's own daily use):**
- The Morning Brief (LON-147/149/151, Anthropic Claude + web_search) is the only LLM-driven surface that actually moves trading decisions today. It works because `web_search` reaches paid sources at query time, bypassing the ingest-velocity ceiling.
- Free-tier news lags the catalyst window by minutes (Finnhub) to hours (SEC EDGAR Atom) — fine for analysis but insufficient for entry timing on small-cap momentum.
- Phase 5's commercial-data negotiation requires Phase 4's user traction first. Building paid-data pipelines pre-traction is expensive infrastructure that may not get the right shape.
- **The pipeline itself isn't wasted.** Switching the source from free to paid is a one-config change once the agreement is in place. All the accumulated work (NewsAnalysis prompts, TradingProfile personalization, dilution pipeline, dedup, broadcast gates) compounds on top of paid data the moment it's flipped.

**Trade-off acknowledged**: News-feed UX work today (multi-ticker dedup, stream refresh quality, filter ergonomics) is framed honestly as "infra polish for the paid-data day" — not as "directly improves trading utility." Avoids the trap of overselling free-tier feature wins.


