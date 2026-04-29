# Long or Short — Agent Context

Real-time news analysis tool for active traders, with small-cap momentum as the primary use case. When a stock pumps on a news catalyst, traders have minutes to decide. This app collapses the manual research loop (repetition check, historical price reaction, strategy filter) into a single AI-generated card delivered to a live feed.

## Stack

- **Elixir / Phoenix LiveView** — fault-tolerant ingestion + real-time UI
- **Ash Framework 3.x + AshPostgres** — declarative resources, code interfaces, policy-based authorization
- **PostgreSQL** — primary store
- **Phoenix PubSub** — inter-module communication
- **Anthropic Claude API** — analysis brain (provider abstraction in place)

## Top-level rules

- **Always Ash, never plain Ecto.** All data access goes through Ash resources and code interfaces.
- **Code interfaces live on the Domain**, not inside resources.
- **Use existing fixtures.** Prefer `build_*` helpers (`build_article`, `build_ticker`) over raw `Ash.create`.
- **No `Process.sleep` in tests.** Use `assert_receive` or direct ETS manipulation for time-based tests.
- **Conversations in Korean.** Responses can be in Korean unless the user switches.

## Where to look

For task-specific context, read the matching doc before making changes:

| When working on... | Read |
|--------------------|------|
| Adding a new news source | `docs/architecture.md`, `docs/domain_info.md` |
| Modifying ingestion flow / PubSub | `docs/architecture.md` |
| Touching Ash resources, actions, identities | `docs/domain_info.md` |
| Understanding why something is the way it is | `docs/design.md` |
| Writing tests, fixtures, or commits | `docs/conventions.md` |
| Knowing what's next | `docs/roadmap.md` |

## Issue tracker

Linear workspace: https://linear.app/long-or-short/

Tickets are prefixed `LON-`. Always confirm with the user before creating new tickets.
