---
description: Start work on a Linear ticket. Presents a plan, then walks through file changes one at a time.
argument-hint: <LON-XX>
---

# Start Ticket: $ARGUMENTS

Begin work on a Long or Short ticket. Follow the phases below **strictly and in order**.

## Phase 0: Ticket Lookup

1. Fetch ticket `$ARGUMENTS` via Linear MCP (`Linear:get_issue`)
2. Summarize for the user: title, description, labels, dependencies (`blockedBy`)
3. If any dependency is not Done, warn the user before proceeding

## Phase 1: Branch Setup

1. Run `git status` and check the current branch + working tree
2. If on a clean `main`, create a new branch: `git checkout -b feat/lon-XX-<short-slug>`
   - If there are uncommitted changes, ask the user how to handle them (stash / commit elsewhere / abort)
3. Report the new branch name to the user

## Phase 2: Present the Plan (NO code changes yet)

In this phase you **must not modify any files**. Plan only.

1. Read relevant files to ground the plan (Ash resources, domain modules, existing tests, etc.). Reference `docs/domain_info.md` and `docs/architecture.md`.
2. Output the plan in this exact shape:

   ```
   ## 📋 Plan for LON-XX

   ### Files to create / modify
   1. `lib/.../foo.ex` — (new/modify) one-line summary
   2. `lib/.../bar.ex` — ...
   3. `test/.../foo_test.exs` — ...

   ### Key decisions
   - ...
   - ...

   ### Impact
   - Migration needed? (yes/no)
   - PubSub topic changes? (yes/no)
   - Existing tests affected?
   ```

3. End with: **"Proceed with this plan? Let me know if anything needs to change."** Then **wait** for the user's response. Do not move on.

## Phase 3: File-by-File Walkthrough

Begin only after the user approves the plan.

**Rules:**
- **One file per response.** Never bundle multiple files into a single message.
- For each file:
  1. State the file path
  2. Show the full code (or, for edits, the changed section with surrounding context)
  3. Explain **why** the code is shaped this way — Ash patterns, policy intent, test strategy, etc.
  4. Actually create or modify the file
- End each response with: **"Show the next file? (`next`, or tell me what to change)"**
- Do not advance to the next file until the user gives a clear signal (`next`, `다음`, `go`, etc.)

### Verify APIs via MCP before writing code

Don't rely on memory for framework APIs — versions drift, and getting it wrong wastes a walkthrough turn. Use the MCP tools available:

**For Ash code (resources, actions, policies, changes, code interfaces):**
- Use the Ash MCP to confirm the API surface — `manage_relationship` options, `change` callback signatures, policy DSL, identity declarations, etc.
- Ash 3.x differs from 2.x in non-trivial ways. Verify before writing.

**For LiveView / HEEx work:**
- Use Tidewave's `search_package_docs` to look up `Phoenix.Component`, `Phoenix.LiveView`, `Phoenix.LiveView.JS` functions
- Use `get_docs` for specific function signatures (e.g. `stream_insert/4`, `assign_async/3`)
- Phoenix LiveView 1.x APIs differ from older versions — don't guess attribute names or callback signatures

**For runtime questions** ("what does this resource look like in memory?", "what's the current state of this process?"):
- Use Tidewave's `project_eval` against the running dev server
- Use `get_ash_resources` to introspect loaded resources

If a tool call fails or the MCP isn't responding, mention it to the user rather than silently falling back to memory.

### Project conventions to enforce while writing code

- All data access goes through Ash domain code interfaces — no plain Ecto
- Tests use `build_article` / `build_ticker` helpers — never `_fixture` suffix
- Business-logic tests use `authorize?: false`; only `describe "policies"` blocks pass an explicit actor
- No `Process.sleep` in tests — use `assert_receive` or direct ETS manipulation
- Code, comments, and module docs in English; conversation stays in the user's chosen language

## Phase 4: Verification

After all files are written:

1. Run `mix compile --warnings-as-errors`
2. Run new/modified tests: `mix test test/path/to/foo_test.exs`
3. If a migration is involved, run `mix ash_postgres.generate_migrations --name <slug>` and review the generated file
4. Report results to the user, then say: **"Run `/finish-ticket` to wrap up."**

---

## Hard rules — do not violate

- ❌ Do not modify any file during the planning phase
- ❌ Do not show more than one file per response during the walkthrough
- ❌ Do not advance to the next file without an explicit user signal
- ❌ Do not change Linear ticket status — that is `/finish-ticket`'s job
- ❌ Do not commit — that is also `/finish-ticket`'s job
