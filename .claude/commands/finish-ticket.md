---
description: Wrap up the current ticket. Verifies build/tests via Tidewave + mix, commits, pushes, opens PR, merges, marks Linear Done, suggests next ticket.
argument-hint: (optional) extra context
---

# Finish Ticket

Wrap up the Long or Short ticket currently in progress. Follow the phases below **strictly and in order**. If any phase fails, **stop immediately** and report to the user — do not silently advance.

## Phase 0: Verification

### 0a. Branch + working tree

1. `git branch --show-current` — must be on a `feat/lon-XX-...` branch
2. Extract the LON ticket number from the branch name
3. `git status` — note uncommitted changes (expected at this point)

### 0b. Compile + tests (mix)

1. `mix compile --warnings-as-errors` — must pass
2. Run relevant tests:
   - If only a few files changed, run their test files: `mix test test/path/to/foo_test.exs`
   - If many files changed or shared infrastructure was touched, run the full suite: `mix test`

### 0c. Runtime verification (Tidewave MCP)

Use Tidewave to confirm the changes actually work in the running app — not just that they compile and unit tests pass. The dev server should already be running with Tidewave plugged in.

**For Ash resource changes:**
- Use `get_ash_resources` to confirm the resource and its actions are loaded correctly
- Use `project_eval` to invoke the new/changed code interface against real data, e.g.:
  ```elixir
  LongOrShort.News.list_recent_articles!(authorize?: false) |> length()
  ```
- For new actions: invoke them with realistic input and confirm the result shape

**For LiveView changes:**
- Use `project_eval` to inspect process state if relevant (PubSub subscriptions, ETS state, etc.)
- Confirm no crashes in recent logs

**For ingestion / pipeline changes:**
- Use `project_eval` to send a synthetic article through the pipeline and confirm broadcast + persistence
- Use `execute_sql_query` to verify DB state matches expectations

**For migrations:**
- Confirm migration ran cleanly and the resulting schema matches the resource definition (Tidewave can introspect both)

If any verification surfaces a bug, **stop and report**. Do not commit broken code.

### 0d. Stop conditions

If anything in Phase 0 fails, stop and show the user the error. Do not auto-fix — the user decides whether to amend the work or abort.

---

## Phase 1: Commit

1. Show `git diff --stat` so the user sees the change footprint
2. Propose a commit message:
   - Format: `<type>(<scope>): <imperative summary> — LON-XX`
   - Examples: `feat(news): add Analyze button to feed page — LON-29`
   - `<type>` is one of: `feat`, `fix`, `refactor`, `test`, `chore`, `docs`
3. Ask: **"Commit with this message?"** and **wait** for approval
4. On approval: `git add -A && git commit -m "..."`

## Phase 2: Push + PR

1. `git push -u origin <branch>`
2. `gh pr create --fill`
   - Make sure the PR body includes `Closes LON-XX` so Linear auto-closes the ticket on merge
   - If `--fill` doesn't capture this, use `--body` explicitly with: change summary + verification notes (mention what was checked via Tidewave) + `Closes LON-XX`
3. Show the PR URL to the user
4. Ask: **"Merge this PR? (`y`/`n`)"** and **wait**

## Phase 3: Merge

If the user approves:

1. `gh pr merge --squash --delete-branch`
2. Sync local main: `git checkout main && git pull`
3. Report results

If the user declines: leave the PR open, report the URL, and stop.

## Phase 4: Linear Done

1. Fetch the ticket via Linear MCP (`Linear:get_issue`)
2. If status is already Done (likely from `Closes LON-XX` + GitHub integration), confirm and skip update
3. Otherwise, update status to Done (`Linear:save_issue`)
4. Confirm: "✅ LON-XX → Done"

## Phase 5: Suggest Next Ticket

1. Use `Linear:list_issues` with **only `limit`** — team/project filters are unreliable in this workspace (see `docs/AGENTS.md`)
2. Filter results to:
   - State: Todo or In Progress
   - All `blockedBy` dependencies are Done
   - Sort by priority ascending (1 = Urgent, 2 = High, 3 = Medium, 4 = Low — lower number = higher priority)
3. Cross-reference with `docs/roadmap.md` to favor tickets in the current sprint focus
4. Present the top 1–3 candidates:

   ```
   ## 🎯 Next ticket candidates

   1. **LON-XX** — Title (Priority: High)
      - One-line summary
      - Why this one: matches current sprint focus / unblocks LON-YY / etc.
   2. **LON-YY** — Title (Priority: Medium)
      - ...

   Run `/start-ticket LON-XX` to begin.
   ```

5. If you can't decide between candidates, ask the user.

---

## Failure handling

- **Compile / mix test failure**: stop and show the error. Do not auto-fix.
- **Tidewave verification failure**: stop and show what the runtime actually returned vs what was expected.
- **Tidewave MCP unavailable** (dev server not running, etc.): warn the user but allow proceeding if mix tests passed — runtime verification is preferred but not strictly blocking.
- **`gh` failure**: suggest checking auth (`gh auth status`)
- **Linear MCP failure**: tell the user to update the ticket manually; continue to Phase 5

## Hard rules — do not violate

- ❌ Do not commit while compile or tests are failing
- ❌ Do not commit while Tidewave verification surfaced a bug (unless user explicitly overrides)
- ❌ Do not force-push without explicit user approval
- ❌ Do not merge without explicit user approval
- ❌ Do not mark Linear Done before the merge succeeds
- ❌ Do not use `--no-verify` to skip git hooks
