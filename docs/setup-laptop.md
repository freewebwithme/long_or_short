# Linux laptop setup — 24/7 dev + data-accumulation server

> **Purpose**: The Linux laptop is the always-on machine that runs the
> Phoenix dev server, accumulates the news/filings/analysis data
> assets, and acts as the morning-brief target from the Windows
> trading laptop. The heavy main desktop is no longer required — all
> code work + 24/7 runtime live on the laptop.

## Architecture

```
[Linux laptop (24/7 dev + server)]              [Windows trading laptop]
- IDE / code editing                             - Lightspeed
- Postgres (data assets: articles, filings,      - Browser → http://<tailscale-ip>:4000
  analyses)                                        Morning Brief on the side
- mix phx.server via systemd (auto-restart)
- Oban cron + Finnhub WS + Alpaca firehose
- Daily pg_dump backups
- Tailscale node
```

**Source of truth**:

- Code: GitHub (`freewebwithme/long_or_short`)
- Data: this laptop's PostgreSQL — `long_or_short_dev`
- Secrets: `envs/.dev.env` on the laptop (never committed)

**Deferred**: Fly.io production deploy (`LON-127` plumbing landed, boot
deferred). When deploy resumes, `pg_dump --data-only` of the laptop
DB transfers articles/filings/analyses straight into prod.

---

## 0. Pre-flight check

```sh
uname -a && cat /etc/os-release | head -3
free -h | head -2
nproc
df -h /
```

Minimum: 4 GB RAM, 2 cores, 20 GB free disk. Ubuntu/Debian commands below;
adapt the package manager for Fedora/Arch/Manjaro if needed.

---

## 1. Install Elixir / Erlang via asdf

```sh
# Build deps
sudo apt update
sudo apt install -y \
  curl git build-essential \
  autoconf m4 libncurses-dev libwxgtk3.2-dev libwxgtk-webview3.2-dev \
  libgl1-mesa-dev libglu1-mesa-dev libpng-dev libssh-dev \
  unixodbc-dev xsltproc fop libxml2-utils libncurses5-dev openjdk-17-jdk \
  inotify-tools

# asdf
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.1
echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc
echo '. "$HOME/.asdf/completions/asdf.bash"' >> ~/.bashrc
exec bash

# Erlang + Elixir (matches .tool-versions)
asdf plugin add erlang
asdf plugin add elixir

asdf install erlang 28.3
asdf install elixir 1.19.4-otp-28

asdf global erlang 28.3
asdf global elixir 1.19.4-otp-28

elixir -v   # → Elixir 1.19.4 (compiled with Erlang/OTP 28)
```

---

## 2. Install PostgreSQL 17

Project migrations rely on `uuidv7()` (Postgres 17 built-in).

```sh
# Add the official PostgreSQL APT repo if the distro ships < 17
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
  https://www.postgresql.org/media/keys/ACCC4CF8.asc
sudo sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
sudo apt update
sudo apt install -y postgresql-17 postgresql-contrib-17

sudo systemctl enable --now postgresql

# Make the OS user a Postgres superuser (dev convenience)
sudo -u postgres createuser -s "$USER"
createdb long_or_short_dev

# Verify uuidv7 is available
psql long_or_short_dev -c "SELECT uuidv7();"
```

---

## 3. SSH key + GitHub access

```sh
ssh-keygen -t ed25519 -C "$USER@$(hostname)"
cat ~/.ssh/id_ed25519.pub
```

Paste the public key into **GitHub → Settings → SSH and GPG keys → New SSH key**.

```sh
ssh -T git@github.com   # "Hi freewebwithme! ..."
```

---

## 4. Clone the project + fetch deps

```sh
mkdir -p ~/projects && cd ~/projects
git clone git@github.com:freewebwithme/long_or_short.git
cd long_or_short

mix local.hex --force
mix local.rebar --force
mix deps.get
```

---

## 5. Secrets (`envs/.dev.env`)

```sh
mkdir -p envs
cat > envs/.dev.env <<'EOF'
DATABASE_URL=ecto://localhost/long_or_short_dev
SECRET_KEY_BASE=__GEN1__
TOKEN_SIGNING_SECRET=__GEN2__

FINNHUB_API_KEY=your_finnhub_key
ANTHROPIC_API_KEY=your_anthropic_key
ALPACA_API_KEY_ID=your_alpaca_paper_key_id
ALPACA_API_SECRET_KEY=your_alpaca_paper_secret
SEC_USER_AGENT=LongOrShort your_email@example.com

# Seed bootstrap (priv/repo/seeds.exs)
ADMIN_EMAIL=your_email@example.com
ADMIN_PASSWORD=strong-password-here
# Optional — trader account. Defaults to admin email + "+trader" and admin password
# TRADER_EMAIL=your_email+trader@example.com
# TRADER_PASSWORD=your-trader-password
EOF

# Fill the two generated secrets
SKB=$(mix phx.gen.secret)
TSS=$(mix phx.gen.secret)
sed -i "s|__GEN1__|$SKB|" envs/.dev.env
sed -i "s|__GEN2__|$TSS|" envs/.dev.env

cat envs/.dev.env  # sanity check
```

**API key sources**:

- Finnhub — <https://finnhub.io>
- Anthropic — <https://console.anthropic.com>
- Alpaca — <https://app.alpaca.markets> → Paper mode → Home → Generate API Keys (secret is shown ONCE)
- `SEC_USER_AGENT` — must include a real contact email; SEC blocks bad UAs

---

## 6. Database setup + admin / trader seed

```sh
mix ash.setup    # creates DB + runs migrations + applies seeds
```

The seed (LON-127) creates the admin user with `confirmed_at` already
set, so you can sign in immediately without a working mailer. Trader
account is derived via plus-addressing — same mailbox, same password
by default, different role.

To re-run only the seed later:

```sh
mix run priv/repo/seeds.exs
```

---

## 7. Smoke test

```sh
mix phx.server
# Open http://localhost:4000 in the laptop's browser
```

- Sign in as admin → `/admin` should load `ash_admin`
- `/morning` should render the Morning Brief shell
- Wait ~60s, then verify articles flow in:

  ```sh
  psql long_or_short_dev -c "SELECT count(*) FROM articles;"
  ```

Stop the server with `Ctrl+C, a`.

---

## 8. Disable sleep / lid-close suspend

```sh
# Mask all sleep-style targets
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# Ignore lid close
sudo sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/'                /etc/systemd/logind.conf
sudo sed -i 's/^#\?HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/^#\?HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/'    /etc/systemd/logind.conf
sudo systemctl restart systemd-logind

# GNOME desktop power settings (skip on headless installs)
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'      2>/dev/null || true
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null || true
```

Verify with `systemctl status sleep.target` — should report `masked`.

> Keep the laptop on AC power and in a ventilated spot. Lid closed is
> fine; just don't trap it on bedding/blankets.

---

## 9. systemd service — auto-start the Phoenix server

Create `/etc/systemd/system/long-or-short.service` (replace `YOUR_USERNAME`):

```ini
[Unit]
Description=Long or Short dev server
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=YOUR_USERNAME
WorkingDirectory=/home/YOUR_USERNAME/projects/long_or_short
Environment="MIX_ENV=dev"
Environment="HOME=/home/YOUR_USERNAME"
Environment="PATH=/home/YOUR_USERNAME/.asdf/shims:/home/YOUR_USERNAME/.asdf/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=/home/YOUR_USERNAME/.asdf/shims/mix phx.server
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Apply:

```sh
sudo sed -i "s|YOUR_USERNAME|$USER|g" /etc/systemd/system/long-or-short.service
sudo systemctl daemon-reload
sudo systemctl enable --now long-or-short
sudo systemctl status long-or-short
journalctl -u long-or-short -f   # live logs
```

After a code change:

```sh
sudo systemctl restart long-or-short
```

Convenient alias:

```sh
echo 'alias restart-app="sudo systemctl restart long-or-short && journalctl -u long-or-short -f"' >> ~/.bashrc
exec bash
```

---

## 10. Tailscale — remote access from the Windows trading laptop

### Linux laptop

```sh
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up   # open the printed URL in a browser to log in
tailscale ip -4     # e.g. 100.x.y.z
```

### Windows trading laptop

Download <https://tailscale.com/download/windows>, sign in with the same
account. Then in any browser:

```
http://100.x.y.z:4000
```

The Morning Brief renders alongside Lightspeed without exposing the
laptop to the public internet (WireGuard mesh, ACL-controlled).

---

## 11. Daily backups

Append to `crontab -e`:

```cron
# Daily 03:00 — dump the data assets
0 3 * * * pg_dump long_or_short_dev | gzip > /home/YOUR_USERNAME/backups/long_or_short-$(date +\%Y\%m\%d).sql.gz

# Weekly Sunday 04:00 — prune backups older than 30 days
0 4 * * 0 find /home/YOUR_USERNAME/backups -name "*.sql.gz" -mtime +30 -delete
```

```sh
mkdir -p ~/backups
```

Recommended additional: weekly sync `~/backups` to external storage
(Backblaze B2, AWS S3 free tier, USB SSD) — protects against disk
failure on the laptop itself.

---

## 12. Day-to-day workflow

- **Code on the laptop directly** — VS Code / Neovim / your editor of choice
- **Commit / push** with the laptop's git config
- **Service auto-restart**: `restart-app` (the alias) after a code change
- **Live logs**: `journalctl -u long-or-short -f`
- **Database console**: `psql long_or_short_dev`
- **Manual seed re-run**: `mix run priv/repo/seeds.exs`
- **Tail Oban jobs**: `psql long_or_short_dev -c "SELECT id, worker, state, scheduled_at FROM oban_jobs ORDER BY id DESC LIMIT 20;"`

---

## 13. When Fly.io deploy resumes (future)

Data on the laptop is the source of truth. The transfer to a fresh
production Postgres is one command per data table:

```sh
# On the laptop
pg_dump --data-only \
  -t tickers -t articles \
  -t filings -t filing_raws -t filing_analyses \
  -t insider_transactions \
  long_or_short_dev > assets.sql

# On the target (Fly Postgres / Neon / Hetzner-self-hosted / ...)
psql $DATABASE_URL < assets.sql
```

Tables to **skip** in the dump: `users`, `tokens`, `source_states`,
`watchlist_items`, `trading_profiles`, `user_profiles`,
`news_analyses` (carries `user_id`).

Production schema comes from the project's migrations (`mix
ash.setup` or `/app/bin/migrate`), so the assets-only dump slots in
cleanly. uuidv7 ids never collide across machines.

---

## Checklist

- [ ] OS + Postgres 17 + Elixir 1.19/OTP 28 installed
- [ ] GitHub SSH key registered, repo cloned to `~/projects/long_or_short`
- [ ] `envs/.dev.env` complete with real API keys + admin credentials
- [ ] `mix ash.setup` ran cleanly, admin user signs in at `/admin`
- [ ] Sleep / lid-close suspends disabled (`systemctl status sleep.target` → masked)
- [ ] `long-or-short.service` enabled and active
- [ ] Tailscale up on the laptop and on the Windows trading laptop
- [ ] Daily `pg_dump` cron entry installed
- [ ] (Optional) Weekly off-machine backup sync

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `mix phx.server` fails: `(Postgrex.Error) FATAL ... password authentication failed` | DB user mismatch | `sudo -u postgres createuser -s "$USER"` again |
| `psql -c "SELECT uuidv7()"` errors `function uuidv7() does not exist` | Postgres < 17 installed | Install `postgresql-17` from the PGDG repo (§2) |
| Server crashes after a few seconds with `:nofile` on `envs/.dev.env` | env file missing or wrong path | Check `pwd`, file must be at `envs/.dev.env` relative to the repo root |
| Articles count stays 0 after 5+ minutes | API key empty / Alpaca paper account not generated | Re-issue keys at app.alpaca.markets, refresh `envs/.dev.env`, `restart-app` |
| systemd service exits immediately with `mix: command not found` | asdf shim path missing in service `Environment=` | Re-add the `PATH=` line with the asdf shims directory |
| Lid close still suspends after the masks | Other power policy still wins | `journalctl -u systemd-logind` to inspect; also check GNOME / DE-specific settings |
