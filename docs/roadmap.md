# Roadmap

> Linear is the source of truth — see https://linear.app/long-or-short/ for ticket-level detail.
> This document explains **"why this order"**. Last updated: 2026-05-15

---

## Vision

Start as a news analysis tool for small-cap momentum traders, ultimately evolve into a **personalized investment AI advisor**.

The core differentiator is the combination of two data streams:
1. **External context** — real-time news, price patterns, market data
2. **Personal context** — trading style (TradingProfile), trade history (journaling), behavioral patterns

Combining these answers the question: "What does this news mean *for your* style and *your* patterns?" That's the essence of an advisor.

---

## Current state at a glance

```
Phase 0: Infrastructure                    ████████████ Complete
Phase 1: AI analysis validation            ███████████░ Mostly done — NewsAnalysis live, dilution epic shipped
Phase 2: Trader workflow integration       ██████████░░ Mostly done — Morning Brief is the proven utility (2026-05-15)
Phase 3: Journaling — personal data        ░░░░░░░░░░░░ Spec only (LON-86, LON-87)
Phase 4: External user acquisition         ░░░░░░░░░░░░ Not started
Phase 5: Commercial data negotiation       ░░░░░░░░░░░░ Not started — paid data unlocks dormant value
Phase 6: AI Advisor evolution              ░░░░░░░░░░░░ Vision
```

**Validation as of 2026-05-15** (the trader's own assessment):

- **Morning Brief is the only surface with proven trading utility.** Used daily, helps actual entry decisions. LON-147/149/151 family.
- **News feed / dashboard cards don't directly help trades yet** — bottlenecked on free-tier news velocity. Infrastructure is correct; the value unlocks at Phase 5 (paid data).
- **Dilution pipeline (LON-131) is fully live** in production-ish mode: SEC EDGAR + body fetch + Tier 1 LLM extract + Tier 2 deterministic scoring + live UI surfaces. Cost is ~$1.19/day at current volume (LON-163/164 brought it down 67%).

---

## Phase 0 — Infrastructure ✅

**Hypothesis**: Elixir/Ash can support a stable real-time news pipeline.

**Validated.** Both Finnhub and SEC EDGAR running reliably. PubSub-based real-time delivery stable.

**Key deliverables**:
- Ash domains + PubSub event contract (LON-7, LON-8, LON-9)
- News.Source behaviour + Pipeline abstraction (LON-18)
- Finnhub polling + WebSocket live price (LON-44, LON-60)
- SEC EDGAR 8-K Atom feed + CIK↔ticker mapping (LON-45, LON-56)
- AI Provider abstraction + Claude implementation (LON-23, LON-24)

---

## Phase 1 — AI analysis validation

**Hypothesis**: AI-generated news analysis genuinely helps traders make entry decisions.

**Status — substantively validated, with caveat.** NewsAnalysis epic (LON-78) shipped end-to-end. The dilution-tracking epic (LON-131, parented under LON-106) shipped its full two-tier extract + score architecture across LON-133/134/135/136/162 + 2026-05-15 hotfixes. Personal daily use confirms the **Morning Brief** (LON-147/149) is where the LLM analysis actually moves trading decisions; the per-article `/feed` analysis works as designed but doesn't beat free-tier news velocity for catalyst-driven entries.

**Key deliverables landed**:
- LON-78 NewsAnalysis end-to-end (resource + analyzer + UI rewire)
- LON-131 two-tier dilution analysis (Phases 0-3b): SmallCapUniverse + Analyzer split + universe-wide Tier 1 cron + Tier 2 background sweep + live UI
- LON-147/149/151 Morning Brief: Anthropic Claude + web_search-driven catalyst digest, three daily windows (premarket / after-open / mid-morning)
- LON-88 TradingProfile per-user persona drives both NewsAnalysis prompts and the Morning Brief

**Phase 1 exit criteria — assessment**:
- [x] Daily personal use, intuitive feel for analysis quality (Morning Brief specifically)
- [x] Patterns identified for when analysis is right vs. wrong (free-tier news limits NewsAnalysis upside; Morning Brief uses web_search to bypass)
- [ ] First round of prompt + TradingProfile tuning beyond the initial pass — pending more daily use

---

## Phase 2 — Trader workflow integration

**Hypothesis**: Good analysis alone isn't enough. Traders need to integrate it naturally into their workflow.

**Status — mostly done, Morning Brief is the workflow win.**

**Done**:
- Dashboard skeleton, navigation, design tokens (LON-70, LON-72)
- Watchlist widget, ticker search, indices widget (LON-73-76)
- File-backed watchlist (LON-64)
- Price + float filters (LON-62 + LON-170 hotfix)
- Live last_price via Finnhub WebSocket trade ticks (LON-60), now with smart-reconnect lifecycle (LON-67)
- Live dilution pills on news cards, PubSub-driven refresh (LON-162)
- **Morning Brief** — three daily catalyst digests with web_search-grounded analysis (LON-147/149/151)
- Operational dashboard wiring: LiveDashboard `/dev/dashboard/metrics` with 65 metrics across 28 events (LON-168/169)

**Remaining milestones**:
- LON-77: Off-hours / closed pill indicator
- LON-63: Relative volume filter (blocked by LON-61 deferred)
- LON-68: Accurate free-float source (FMP / Polygon) — proxy via Finnhub `shareOutstanding` good enough for now (LON-167 expanded coverage to ~1,900 small caps)
- LON-148: Morning Brief Qwen fallback if Anthropic budget tightens (deferred — current burn is comfortable)

---

## Phase 3 — Journaling: personal data accumulation begins

**Hypothesis**: Once a trader's own trade data accumulates, the depth of personalized analysis changes qualitatively.

**Why this timing**: Phase 1-2 must be validated and in daily personal use first. Otherwise the journal stays empty. Building this too early just creates abandoned infrastructure.

**Spec stage (not started)**:
- **LON-86**: Stock journaling (Lightspeed) — Phase 1 ships without OHLC charts
- **LON-87**: Futures journaling (NinjaTrader) — Phase 1 same, charts deferred

**Key design decisions (already agreed)**:
- Chart library + PriceBar work deferred to Phase 2 of journaling, shared across stocks/futures (do it once)
- Data source still undecided — Polygon $29/mo vs. Lightspeed export vs. manual
- Phase 1: trade metadata only (entry/exit/PnL) → baseline for pattern extraction

**Phase 3 exit criteria**:
- [ ] 30-50 personal trades recorded in the system
- [ ] Per-trade notes, tags, outcome tracking working
- [ ] Simple statistics extractable ("I lose often in this pattern")
- [ ] First experiment injecting this data as context into NewsAnalysis (follow-up tickets needed under LON-78)

---

## Phase 4 — External user acquisition

**Hypothesis**: A tool I'd use daily = a tool other traders find valuable.

**Why this timing**: Only after sustained personal use + journaling can I confidently recommend it to other traders.

**Required work**:
- Auth/onboarding refinement (currently solo — sign-up flow needs polish)
- Make new users with free-tier-only data feel value (paste analysis + SEC EDGAR — enough?)
- Feedback collection mechanism (form or direct interview)
- First 5-10 external users + regular interviews

**Phase 4 exit criteria**:
- [ ] 5-10 external traders using regularly
- [ ] More than half respond "I'd pay for this"
- [ ] 3-5 critical missing features identified

---

## Phase 5 — Commercial data negotiation

**Hypothesis**: With a user base and proven retention, premium data sources (Benzinga/Polygon) become accessible via startup discounts.

**Critical**: Running SaaS on individual licenses violates ToS. Without a commercial agreement, premium data isn't usable. So Phase 4's goal — proving traction with free sources — is the prerequisite for negotiating leverage.

**Targets**:
- Benzinga Pro (real-time news + ticker tagging)
- Polygon.io (price + float)
- PR Newswire (press releases)

**Phase 5 exit criteria**:
- [ ] At least one commercial data agreement signed
- [ ] Paid tier pricing model decided + free/paid differentiation

---

## Phase 6 — Evolution to AI Advisor

**Vision**: Move from "news analysis tool" → "AI that knows this trader's patterns and combines them with market context to give advice".

**Why this becomes possible**: Everything accumulated in Phase 1-5 is the raw material for an advisor.
- News analysis (Phase 1) → "what does this information mean"
- TradingProfile (already exists) → "fits this user's style"
- Journal data (Phase 3) → "how did this user fare in similar situations"
- Market context (Phase 2) → "what's the market environment now"

**Anticipated milestones**:
- Trade pattern learning — automatic strength/weakness extraction per user
- Proactive insights — "You win 90% on RVOL > 5x, 30% under 2x"
- Stage-aware advice — different insights pre-entry / during hold / pre-exit
- Multi-modality — chart image input, voice memos, etc.

**⚠️ Important regulatory review**:
- "Investment advisor" in the US is SEC-regulated (40 Act, RIA registration)
- Clear legal boundary needed between "information provision" / "analysis tool" / "automated advice"
- Disclaimer + ToS + correct positioning essential
- Get legal counsel before entering Phase 6 — costly to fix retroactively

**Phase 6 exit criteria**: (Too far out to define meaningfully right now. Revisit during Phase 5.)

---

## Cross-cutting concerns

Things to keep an eye on regardless of phase progression.

### AI cost optimization (LON-35 epic)
- Tier 1 dilution pipeline burn: ~$1.19/day at current volume after the LON-163 (retry-with-backoff) + LON-164 (section dedup) hotfixes — 67% reduction from the pre-fix baseline
- Morning Brief: Claude Sonnet 4.6 with web_search, one call per window × 3 windows × ~weekday cadence — currently in single-digit-dollar/month territory
- Becomes critical from Phase 4 (external users) onward
- Open follow-ups: embedding-based repetition detection (LON-40), watchlist triggers (LON-36), prompt caching

### SystemActor → proper auth (LON-15)
- Must migrate before any external API exposure (JSON API/GraphQL)
- Right before Phase 4 entry is the appropriate moment

### Infrastructure / ops
- Deployment environment (Fly.io — LON-126 epic) — **on hold**, LON-127 sub-ticket cancelled 2026-05-13. Resume when solo daily-use is steady-state (essentially now, but trader hasn't given the green light)
- Operational telemetry — wired (LON-161 + LON-168/169 land it on LiveDashboard + dev console)
- Backpressure policy consolidated in `docs/architecture.md` (LON-161)
- Backup / disaster recovery — Phase 5 timeframe

### Paid data unlock — the dormant value lever
- Free-tier news (Finnhub, Alpaca, SEC EDGAR) populates the pipeline but doesn't move trading decisions on its own
- Phase 5 negotiation targets (Benzinga / Polygon / PR Newswire) are exactly what the NewsAnalysis surface needs to start winning
- Roadmap thesis: build the infra now, switch the source then, instant ROI on accumulated work

---

## 2026-05 progress snapshot

### Dilution epic (LON-131, parent LON-106) — shipped end-to-end this month
1. **Phase 0** (LON-133): IWM CSV baseline + SEC EDGAR top-up → `SmallCapUniverse` membership table (~1,917 active members)
2. **Phase 1** (LON-134): `Filings.Analyzer` two-tier split — cheap `extract_keywords` + deterministic `score_severity`
3. **Phase 2** (LON-135): `FilingAnalysisWorker` runs Tier 1 over the universe every 15 min; per-run + today-total cost telemetry
4. **Phase 3a** (LON-136): `FilingSeverityWorker` background sweep promotes Tier 1 rows to fully scored every 5 min
5. **Phase 3b** (LON-162): live read from `get_dilution_profile/1` across `/feed`, `/`, `/morning`, `/analyze` + PubSub re-render

### Real-data baseline + hotfix bursts (2026-05-15)
- **LON-163**: SystemActor wiring fix + `AI.call/3` retry-with-backoff on 429
- **LON-164**: `SectionFilter` dedup — TOC + body + cross-reference chunks were inflating Tier 1 input tokens 3-5×
- **LON-165**: Oban unique constraint on `FilingAnalysisWorker` — prevents concurrent Tier 1 batches from compounding rate-limit hits
- **LON-167**: `FinnhubProfileSync` symbol source expanded from `tracked_tickers.txt` (~29) to the union of that + active small-cap universe (~1,941). Daily 05:00 UTC.
- **LON-170**: `/feed` price/float filter no longer crashes / drops ticker selection on form change

### Operational observability (2026-05-15)
- **LON-161**: Tier 1 ingest health daily reporter (06:00 UTC) + per-event CIK-drop telemetry + consolidated backpressure table in `architecture.md`
- **LON-67**: `FinnhubStream` graceful shutdown + smart reconnect (429 → stop, transient → exp backoff + cap) + lifecycle telemetry
- **LON-168/169**: 65 metrics across 28 events wired into `LongOrShortWeb.Telemetry`. `ConsoleReporter` dev-only, filtered to `[:long_or_short, ...]` domain events (excludes `:repo` to avoid drowning the dev IEx)

---

## Decision principles

Questions to revisit each time when applying this roadmap:

1. **"Does this help validate the next phase's hypothesis?"**
   If not, defer it or move to cross-cutting concerns.

2. **"Am I using it daily?"**
   Can't recommend a feature to external users that I don't use myself.

3. **"Is there a licensing / regulatory risk?"**
   Especially critical for data redistribution (Phase 5) and advisor positioning (Phase 6).

4. **"Is this decision consistent with the advisor vision?"**
   If a short-term win conflicts with the long-term vision, pause and reconsider.
