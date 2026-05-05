---
description: Scan recently completed tickets and suggest the next ticket to work on.
argument-hint: (optional) area of focus, e.g. "ai" or "ui"
---

# Find Next Ticket

Scan recently completed Linear tickets in the Long or Short workspace and recommend what to work on next. This is a **read-only** command — do not modify any tickets, branches, or files.

## Phase 0: Confirm clean state

1. `git branch --show-current` — should be `main` (or report which branch we're on)
2. `git status` — note if there are uncommitted changes
3. If we're mid-ticket (on a `feat/lon-XX-...` branch with changes), warn the user — they probably want `/finish-ticket` instead

## Phase 1: Scan recent activity

1. Use `Linear:list_issues` with **only `limit`** (e.g. `limit: 50`) — workspace filters are unreliable, see `docs/AGENTS.md`
2. Identify recently completed tickets:
   - State: Done or Cancelled, sorted by `updatedAt` desc
   - Take the most recent 5–10
3. Build a quick summary:

   ```
   ## ✅ Recently closed

   - **LON-XX** — Title (Done, 2 days ago)
   - **LON-YY** — Title (Done, 5 days ago)
   - **LON-ZZ** — Title (Cancelled, 1 week ago)
   ```

   Mention any patterns: e.g. "the last 3 closed tickets all belonged to the LON-52 epic — that epic looks complete."

## Phase 2: Identify ready work

1. From the same `list_issues` result, filter for actionable tickets:
   - State: Todo or In Progress (favor In Progress if any exist — they may be partially started)
   - All `blockedBy` dependencies are Done
   - Not already merged via a PR (cross-check by title if needed)
2. If a focus argument was given (`$ARGUMENTS`), filter further by labels or title keyword match
3. Sort by priority: 1 (Urgent) → 2 (High) → 3 (Medium) → 4 (Low) → no priority

## Phase 3: Cross-reference roadmap

1. Read `docs/roadmap.md` for the current sprint focus
2. Boost tickets that match the sprint focus
3. Note any tickets blocked by the recently-closed work — those just became unblocked and are good candidates

## Phase 4: Present recommendations

Output in this shape:

```
## 🎯 Recommended next tickets

### Top pick
**LON-XX** — Title
- Priority: High
- Why: matches current sprint focus (LON-22 epic), unblocked by LON-YY merge yesterday
- Estimated scope: small / medium / large (based on description)

### Also viable
1. **LON-AA** — Title (Priority: Medium)
   - Why: ...
2. **LON-BB** — Title (Priority: Medium)
   - Why: ...

### Blocked but coming up
- **LON-CC** (waiting on LON-AA)

Run `/start-ticket LON-XX` to begin.
```

If nothing actionable exists (everything blocked or no Todos), say so plainly and suggest unblocking work or backlog grooming.

---

## Hard rules — do not violate

- ❌ Do not modify any Linear ticket (no status changes, no comments)
- ❌ Do not create branches, commits, or PRs
- ❌ Do not edit any project files
- ❌ Do not start the ticket — recommendation only. The user runs `/start-ticket` separately.
