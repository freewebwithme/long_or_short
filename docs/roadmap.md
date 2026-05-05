# Roadmap

> Linear is the source of truth — see https://linear.app/long-or-short/ for ticket-level detail.
> This document explains **"why this order"**. Last updated: 2026-05-05

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
Phase 1: AI analysis validation            ██████░░░░░░ In progress (LON-78 nearly done)
Phase 2: Trader workflow integration       ████████░░░░ Mostly done (LON-69 done, LON-58 partial)
Phase 3: Journaling — personal data        ░░░░░░░░░░░░ Spec only (LON-86, LON-87)
Phase 4: External user acquisition         ░░░░░░░░░░░░ Not started
Phase 5: Commercial data negotiation       ░░░░░░░░░░░░ Not started
Phase 6: AI Advisor evolution              ░░░░░░░░░░░░ Vision
```

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

## Phase 1 — AI analysis validation (current)

**Hypothesis**: AI-generated news analysis genuinely helps traders make entry decisions.

**Why this matters most**: If this isn't validated, every other phase is meaningless. This is the app's core value proposition.

**Current state**: NewsAnalysis epic (LON-78) nearly complete. Backend works, only UI wiring remains.

**Remaining milestones**:
- **LON-83**: `/feed` Analyze button + 6-signal card UI rewire
- **LON-84**: Manual article ingest action
- **LON-85**: `/analyze` paste-driven page — sidesteps licensing + accelerates validation

**Phase 1 exit criteria**:
- [ ] Daily personal use, intuitive feel for analysis quality
- [ ] Patterns identified for when analysis is right vs. wrong
- [ ] First round of prompt + TradingProfile tuning

---

## Phase 2 — Trader workflow integration

**Hypothesis**: Good analysis alone isn't enough. Traders need to integrate it naturally into their workflow.

**Current state**: Dashboard epic (LON-69) complete, Filter epic (LON-58) partially complete.

**Done**:
- Dashboard skeleton, navigation, design tokens (LON-70, LON-72)
- Watchlist widget, ticker search, indices widget (LON-73, LON-74, LON-75, LON-76)
- File-backed watchlist (LON-64)
- Price + float filters (LON-62)

**Remaining milestones**:
- LON-77: Off-hours / closed pill indicator
- LON-63: Relative volume filter (blocked by LON-61 deferred)
- LON-68: Accurate free-float source (FMP)

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
- Negligible right now (solo use)
- Becomes critical from Phase 4 (external users) onward
- Embedding-based repetition detection (LON-40), watchlist triggers (LON-36), caching, etc.

### SystemActor → proper auth (LON-15)
- Must migrate before any external API exposure (JSON API/GraphQL)
- Right before Phase 4 entry is the appropriate moment

### Infrastructure / ops
- Deployment environment (Fly.io etc.) — just before Phase 4
- Monitoring / logging — just before Phase 4
- Backup / disaster recovery — Phase 5 timeframe

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
