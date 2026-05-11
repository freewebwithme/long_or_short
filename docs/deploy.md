# Deploy guide

Day-1 runbook for operating long-or-short on Fly.io. Pairs with
LON-127 (initial deploy) and LON-126 (epic).

## Overview

- **App**: `long-or-short.fly.dev`
- **Region**: `iad` (US East, Ashburn VA) — co-located with SEC EDGAR / Finnhub / Anthropic
- **Postgres**: Fly Managed Postgres (`fly mpg`), `iad`, single-node, 1 GB RAM / 10 GB disk
- **VM**: shared-cpu-1x, 512 MB, 1 always-on machine (Oban cron + Finnhub WS pinned)
- **AI providers**: Claude (default), Qwen via DashScope Singapore endpoint (LON-104)

## Prerequisites

```sh
brew install flyctl      # or download from fly.io
fly auth login
```

## First deploy (one-time)

1. **Reserve app slot**:

   ```sh
   fly launch --no-deploy --copy-config=false --name long-or-short --region iad
   ```

   This claims the global name. If the name is taken, pick another and update
   `fly.toml`'s `app =` accordingly.

2. **Provision Postgres** (region must match the app):

   ```sh
   fly mpg create
   # region: iad, RAM: 1 GB, disk: 10 GB, single-node
   ```

   Capture the connection string from the output — needed for `DATABASE_URL`.

3. **Set all secrets** (see [Secrets](#secrets) below). Verify with `fly secrets list`.

4. **First deploy**:

   ```sh
   fly deploy
   ```

   - Builds the image
   - Runs `release_command = /app/bin/migrate` against fresh Postgres
   - Starts the Machine

5. **Seed admin + trader users** (one-time after first migration):

   ```sh
   fly ssh console -C "/app/bin/long_or_short eval LongOrShort.Release.seed"
   ```

   Requires `ADMIN_EMAIL` + `ADMIN_PASSWORD` secrets set. Re-running the seed
   is safe — every block short-circuits on existing rows.

6. **Smoke-test**:

   - `curl https://long-or-short.fly.dev/health` → `ok`
   - `https://long-or-short.fly.dev/` → sign-in page renders over HTTPS
   - Sign in as admin → `/admin` loads ash_admin UI
   - Sign in as trader → `/analyze` end-to-end (paste flow → NewsAnalysis card)
   - `fly logs` shows Oban supervisor start, no crash loops

## Secrets

Set with `fly secrets set KEY=value`. Values are masked at rest; `fly secrets list`
shows only the keys.

| Key | Source | Required | Notes |
|---|---|---|---|
| `SECRET_KEY_BASE` | `mix phx.gen.secret` | ✅ | Phoenix session signing |
| `TOKEN_SIGNING_SECRET` | `mix phx.gen.secret` | ✅ | AshAuthentication JWT signing |
| `DATABASE_URL` | `fly mpg create` output | ✅ | Postgres connection string |
| `ANTHROPIC_API_KEY` | console.anthropic.com | ✅ | Claude provider |
| `QWEN_API_KEY` | DashScope Singapore | optional | Required only if `AI_PROVIDER=qwen` |
| `FINNHUB_API_KEY` | finnhub.io | ✅ | News + price stream |
| `SEC_USER_AGENT` | own contact email | ✅ | Format `"AppName contact@email.com"` — SEC blocks bad UA |
| `ADMIN_EMAIL` | own email | ✅ | Admin user — seed bootstrap |
| `ADMIN_PASSWORD` | own choice | ✅ | Admin password — seed bootstrap |
| `TRADER_EMAIL` | own email | optional | Defaults to plus-addressed `ADMIN_EMAIL` (`local+trader@domain`) |
| `TRADER_PASSWORD` | own choice | optional | Defaults to `ADMIN_PASSWORD` |

Plain config (not secrets) — already in `fly.toml [env]`:

- `PHX_HOST = "long-or-short.fly.dev"`
- `PHX_SERVER = "true"`
- `ECTO_IPV6 = "true"` (Fly internal Postgres uses IPv6 `.flycast` addrs)
- `AI_PROVIDER = "claude"`
- `QWEN_REGION = "singapore"`

Bulk-set example:

```sh
fly secrets set \
  SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  TOKEN_SIGNING_SECRET="$(mix phx.gen.secret)" \
  DATABASE_URL="postgres://..." \
  ANTHROPIC_API_KEY="sk-ant-..." \
  FINNHUB_API_KEY="..." \
  SEC_USER_AGENT="LongOrShort you@example.com" \
  ADMIN_EMAIL="you@example.com" \
  ADMIN_PASSWORD="strong-password-here"
```

## Day-1 commands

| Task | Command |
|---|---|
| Deploy | `fly deploy` |
| Stream logs | `fly logs` |
| App status / machines | `fly status` |
| Postgres console | `fly mpg connect <db-name>` |
| IEx remote shell | `fly ssh console -C "/app/bin/long_or_short remote"` |
| Container shell | `fly ssh console` |
| Re-run migrations | `fly ssh console -C "/app/bin/migrate"` |
| Re-run seed | `fly ssh console -C "/app/bin/long_or_short eval LongOrShort.Release.seed"` |
| Rotate a secret | `fly secrets set KEY=new` (auto-redeploys) |
| Restart machine | `fly machine restart <id>` (find id via `fly status`) |

## Rollback

```sh
fly releases             # list past releases with image digests
fly deploy --image registry.fly.io/long-or-short:deployment-<id>
```

DB rollback (rare — only for destructive migrations):

```sh
fly ssh console -C "/app/bin/long_or_short eval 'LongOrShort.Release.rollback(LongOrShort.Repo, <version>)'"
```

`<version>` is the timestamp prefix of the migration to roll back **to** (inclusive
above that version).

## Known gaps (deferred from LON-127)

Not bugs — explicit choices documented for the next operator:

- **Mailer = `Swoosh.Adapters.Local`** — password-reset / confirmation emails never leave the app. Sign-up via the UI only works for users created through the seed (which sets `confirmed_at` directly). Wire a real adapter (Resend / Mailgun / SES) before Phase 4 external users.
- **Custom domain** — `*.fly.dev` only for now. LON-126 follow-up.
- **Monitoring / log shipping / uptime checks** — Fly's built-in metrics only. No Sentry / Honeycomb / external uptime.
- **GitHub Actions auto-deploy** — manual `fly deploy` from laptop is the Phase 1 workflow.
- **Backup restore drill** — Fly MPG includes automated daily snapshots; restore has not been practiced.
- **Multi-region / read replicas / Erlang clustering** — single-machine. Revisit at Phase 4.
- **Staging env** — single prod environment only.

## References

- Phoenix releases: <https://hexdocs.pm/phoenix/releases.html>
- Fly Elixir guide: <https://fly.io/docs/elixir/getting-started/>
- Fly Managed Postgres: <https://fly.io/docs/mpg/>
- LON-127 (initial deploy ticket)
- LON-126 (deploy epic — custom domain / monitoring / backups)
