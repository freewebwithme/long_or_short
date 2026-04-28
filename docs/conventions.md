# Conventions

## Ash patterns

### Code interfaces on the Domain
All public functions live on the Domain module, not the Resource. Inside resources, use `define :function_name, action: :action_name` blocks within `resources do` block of the domain.

```elixir
# ✅ correct — defined in lib/long_or_short/news.ex
resources do
  resource LongOrShort.News.Article do
    define :ingest_article, action: :ingest
    define :get_article, action: :read, get_by: [:id]
  end
end

# ❌ wrong — don't put `define` inside the resource itself
```

### Actions, not changesets
Never construct an `Ash.Changeset` manually in application code. Use the action via the domain code interface.

```elixir
# ✅ correct
{:ok, article} = LongOrShort.News.ingest_article(attrs, actor: SystemActor.new())

# ❌ wrong
%Article{} |> Ash.Changeset.for_create(:ingest, attrs) |> Ash.create()
```

### Authorize? in tests
- **Business logic tests**: `authorize?: false`. The test is about the action's behavior, not the policy.
- **Policy tests**: explicit `actor:` with full policy enforcement. The test is about who can do what.

This split keeps test failures readable: a business-logic test failing on a policy means the test was wrong, not the code.

---

## Fixtures

### Naming
- `build_*` — returns an Ash struct ready for use (or already created)
- `valid_*_attrs` — returns a raw attribute map, no creation

```elixir
# ✅
build_article(symbol: "BTBD")
build_ticker(%{symbol: "AAPL"})
valid_article_attrs(%{title: "..."})

# ❌
article_fixture(...)    # uses suffix instead of prefix
make_article(...)
```

### Location
- `test/support/accounts_fixtures.ex`
- `test/support/news_fixtures.ex`
- `test/support/tickers_fixtures.ex`

### Rule of three
Don't extract a helper until you've written it three times. Specifically: shared test helpers like `error_on_field?/2`, `register_user!/1` move to `AccountsFixtures` only at the third occurrence.

---

## Tests

### No `Process.sleep`
For TTL or time-dependent tests, manipulate the storage directly (e.g. inject an expired ETS timestamp). For PubSub tests, use `assert_receive` with an explicit timeout.

```elixir
# ✅ deterministic
expired_time = System.system_time(:millisecond) - (ttl_ms + 1_000)
key = :crypto.hash(:sha256, "benzinga|abc|BTBD")
:ets.insert(:news_seen, {key, expired_time})
send(Process.whereis(Dedup), :cleanup)
_ = :sys.get_state(Dedup)  # synchronization

# ✅ deterministic
Events.subscribe()
Events.broadcast_new_article(article)
assert_receive {:new_article, ^article}, 100

# ❌ flaky
Process.sleep(1_100)
```

### Ash error matching
- `Ash.Error.Invalid` wraps inner errors like `Ash.Error.Query.NotFound`. Assert on the inner error type, not just the outer.
- Read policies with `nil` actor return `{:ok, []}`, not `{:error, Forbidden}`.

### Filter pin operator
Variable interpolation in `Ash.Query.filter` requires `^`:
```elixir
Ash.Query.filter(query, id == ^my_id)
```

---

## Linear workflow

- Linear MCP tool used for issue management
- **Always confirm** with the user before creating new tickets — don't presume
- Priority is integer: `2` = High, `3` = Medium, `4` = Low
- `blockedBy` takes an array of issue ID strings (e.g. `["LON-53"]`)
- Labels must be created via `create_issue_label` before being applied — passing nonexistent labels at creation silently fails

---

## Git / commits

- Commit messages: imperative, concise (`add`, `fix`, `refactor`, `remove`)
- Reference Linear ticket when applicable: `feat(news): add Finnhub source — LON-44`
- One PR per ticket (typically). Bundling unrelated work makes review harder.

---

## Language

- **Conversations in Korean** by default
- **Code, comments, and module docs in English**
- **Linear ticket descriptions in English** for searchability
- **Commit messages in English**
