# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ex_cldr, default_backend: LongOrShort.Cldr
config :ash_oban, pro?: false

# IANA timezone database (LON-129). Required for
# `DateTime.shift_zone/2` to resolve names like "America/New_York"
# — used by the Morning Brief feed's ET time-bucket classifier.
# Without this, shift_zone falls back to UTC-only and ET conversion
# silently no-ops.
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :long_or_short, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  # `filings_analysis` is held to concurrency 2 because every job in
  # this queue makes a paid LLM call (LON-115). Tuning higher means
  # tuning provider rate limits + monthly cost simultaneously.
  queues: [default: 10, filings_analysis: 2],
  repo: LongOrShort.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # Daily at 04:00 UTC — SEC mapping refresh (large, run first)
       {"0 4 * * *", LongOrShort.Sec.CikSyncWorker},
       # Daily at 05:00 UTC (~1am EST) — well after US market close.
       {"0 5 * * *", LongOrShort.Tickers.Workers.FinnhubProfileSync},
       # Hourly at :15 — fetch SEC bodies for any new Filings (LON-119).
       # Idempotent + batched (100/cycle), so frequent runs are cheap and
       # keep newly-ingested filings ready for Stage 3a within ~minutes.
       {"15 * * * *", LongOrShort.Filings.Workers.FilingBodyFetcher},
       # Every 15 min — analyze new dilution-relevant filings for
       # watchlist tickers (LON-115, Stage 3c). Picks up FilingRaws
       # that the body fetcher landed and runs the LLM extraction +
       # severity scoring. Watchlist-scoped: cost is bounded by the
       # number of tickers traders have explicitly opted into.
       {"*/15 * * * *", LongOrShort.Filings.Workers.FilingAnalysisWorker},
       # Every 5 min — promote Tier-1-only FilingAnalysis rows to fully
       # scored via Filings.Scoring (LON-136, Phase 3a). Background
       # sweep because LON-160 decided Tier 2 (currently deterministic +
       # $0) has no cost reason to defer to user action. Faster than
       # Tier 1's */15 so trader sees full severity within minutes of
       # Tier 1 landing. Idempotent — filter excludes already-scored rows.
       {"*/5 * * * *", LongOrShort.Filings.Workers.FilingSeverityWorker},
       # Hourly at :30 — parse Form 4 (insider transactions) into
       # InsiderTransaction rows (LON-118). Parallel path to the
       # LLM extraction pipeline: Form 4 is structured XML, parsed
       # directly. Cadence is intentionally slower than the LLM
       # pipeline — Form 4 signal value is day-bound, not minute-bound.
       {"30 * * * *", LongOrShort.Filings.Workers.Form4Worker},
       # Morning catalyst boundaries — force every enabled news
       # feeder to poll at the top-of-hour / bottom-of-hour windows
       # so we never miss an earnings / FDA / jobs release. The
       # cron fires UTC every :00 / :30; the worker itself filters
       # to ET 07:00–10:30 Mon–Fri (Oban 2.21's 3-tuple cron entry
       # accepts job-options only — no per-entry `timezone` — and
       # promoting the plugin-level `timezone` would shift the
       # other UTC-anchored daily jobs above). Idempotent — dedup
       # absorbs duplicates the regular 60s timer would otherwise
       # produce in the same window.
       {"0,30 * * * *", LongOrShort.News.MorningBoundaryPollWorker},
       # Morning Brief generation — every 15min UTC; the worker
       # itself filters to the three ET wall-clock windows
       # (05:00 / 08:45 / 10:15 ET) on weekdays (LON-151). Same
       # worker-side-filter pattern as the boundary poll above —
       # we can't promote a per-entry timezone without shifting
       # the UTC-anchored daily jobs at the top of this list.
       {"0,15,30,45 * * * *", LongOrShort.MorningBrief.CronWorker},
       # Weekly Monday 06:00 UTC (~01:00–02:00 ET, dead pre-market) —
       # refresh the small-cap universe from iShares IWM holdings CSV
       # (LON-133, Phase 0). Daily would re-download the same data
       # since Russell 2000 changes slowly; weekly is the right
       # cadence for IPO adds + occasional rebalances. Runs after
       # CikSyncWorker (04:00) and FinnhubProfileSync (05:00) so
       # newly-added R2K tickers already have CIK + profile data
       # when this worker upserts them.
       {"0 6 * * 1", LongOrShort.Tickers.Workers.IwmUniverseSync},
       # Daily at 06:00 UTC — surface Tier 1 ingest health
       # (CIK drops + FilingAnalysis rejection rate) for the
       # previous 24h (LON-161). Reads + resets the in-memory
       # CIK drop counter; pulls rejection aggregate from
       # `filing_analyses`. Logs a summary line and emits
       # `[:long_or_short, :ingest_health, :daily_summary]`
       # telemetry. Co-runs with the weekly IwmUniverseSync
       # on Mondays — separate jobs, no contention.
       {"0 6 * * *", LongOrShort.Filings.Workers.IngestHealthReporter}
     ]}
  ]

config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec, AshMoney.Types.Money],
  custom_types: [money: AshMoney.Types.Money]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :admin,
        :multitenancy,
        :postgres,
        :identities,
        :attributes,
        :relationships,
        :cloak,
        :calculations,
        :aggregates,
        :authentication,
        :tokens,
        :resource,
        :code_interface,
        :actions,
        :forms,
        :changes,
        :validations,
        :policies,
        :pub_sub,
        :preparations,
        :paper_trail
      ]
    ],
    "Ash.Domain": [
      section_order: [:admin, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

config :long_or_short,
  ecto_repos: [LongOrShort.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    LongOrShort.Accounts,
    LongOrShort.News,
    LongOrShort.Tickers,
    LongOrShort.Sources,
    LongOrShort.Analysis,
    LongOrShort.Filings,
    LongOrShort.Settings,
    LongOrShort.Research
  ]

# Configure the endpoint
config :long_or_short, LongOrShortWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LongOrShortWeb.ErrorHTML, json: LongOrShortWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: LongOrShort.PubSub,
  live_view: [signing_salt: "1tHyhrzJ"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :long_or_short, LongOrShort.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  long_or_short: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  long_or_short: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Filings ingestion (LON-106 epic).
# Children of LongOrShort.Filings.SourceSupervisor. Defaults to [];
# enable per environment (dev / prod) once a feeder cadence is decided.
config :long_or_short, :enabled_filing_sources, []

# Sink for parsed filings — routes through the Filings Ash domain
# (LON-112).
#
# We expose the sink as a swappable function rather than calling
# `Filings.ingest_filing/1` directly from the Pipeline because:
#
#   1. Test isolation — pipeline unit tests inject their own sink
#      via the state map or `Application.put_env`, so they verify
#      dispatch behavior without touching the database.
#   2. Compile decoupling — `LongOrShort.Filings.Sources.*` would
#      otherwise have to know about the `Filings` domain at compile
#      time. Routing through app env keeps Sources unaware of who
#      consumes its output.
#   3. Environment routing — leaves room for non-DB sinks later
#      (dry-run mode, Kafka tee, archival, etc.) via config alone,
#      no code change required.
#
# Same pattern as `:ai_provider` below.
config :long_or_short, :filings_ingest_fun, &LongOrShort.Filings.ingest_filing_as_system/1

# Form types polled by LongOrShort.Filings.Sources.SecEdgar.
# Each atom must be a key in SecEdgar's `@form_type_map`.
config :long_or_short,
       :dilution_filing_types,
       [
         :s1,
         :s1a,
         :s3,
         :s3a,
         :_424b1,
         :_424b2,
         :_424b3,
         :_424b4,
         :_424b5,
         :_8k,
         :_13d,
         :_13g,
         :def14a,
         :form4
       ]

# Window (days) for `LongOrShort.Tickers.get_dilution_profile/1`
# window-based aggregation (LON-116, Stage 4). FilingAnalysis rows
# whose `filing.filed_at` is older than this cutoff are excluded
# from `pending_s1` / `warrant_overhang` / `recent_reverse_split`.
#
# ATM lifecycle tracking (`LongOrShort.Filings.AtmLifecycle`) is
# intentionally *not* window-bound — an ATM registered 12 months
# ago can still hang active capacity over the float today.
config :long_or_short, :dilution_profile_window_days, 180

# Window (days) for `LongOrShort.Filings.InsiderCrossReference`
# (LON-118, Stage 9). Insider open-market sales within this many
# days *after* the latest dilution-relevant filing trigger
# `:insider_selling_post_filing = true` on the dilution profile.
# 30d is the Phase 1 default; LON-121 calibration may tune it
# based on real outcome tracking.
config :long_or_short, :insider_post_filing_window_days, 30

# AI provider — defaults to Claude in dev/prod, overridden in test.
# `runtime.exs` reads the `AI_PROVIDER` env var and may swap this for
# a different provider module (e.g. Qwen) at boot.
config :long_or_short, :ai_provider, LongOrShort.AI.Providers.Claude

config :long_or_short, LongOrShort.AI.Providers.Claude,
  model: "claude-sonnet-4-6",
  max_tokens: 4096,
  base_url: "https://api.anthropic.com",
  anthropic_version: "2023-06-01",
  # Anthropic's web_search tool is version-dated; bump here when they
  # release a newer revision (LON-150).
  web_search_tool_version: "web_search_20250305"

# Qwen / DashScope provider defaults (LON-104). Region-specific base
# URLs — `runtime.exs` selects which one is active via `QWEN_REGION`.
# Singapore is the free-tier dev/test region; US Virginia is
# production pay-as-you-go.
config :long_or_short, LongOrShort.AI.Providers.Qwen,
  model: "qwen3-max",
  max_tokens: 4096,
  base_urls: %{
    singapore: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
    us: "https://dashscope-us.aliyuncs.com/compatible-mode/v1"
  }

# Default Qwen region — `runtime.exs` overrides from `QWEN_REGION`.
# Setting it here ensures dev/test (which skip runtime.exs in some
# flows) still has a value if the provider is exercised.
config :long_or_short, :qwen_region, :singapore

# Morning Brief provider (LON-151). Module that exports
# `call_with_search/2` returning `{:ok, %{text, citations, usage,
# search_calls}}`. Defaults to Claude (LON-149 Phase 1 — Haiku 4.5
# per `ANTHROPIC_MODEL` env, escapable to Sonnet 4.6 by env flip).
# LON-148 will swap this to `LongOrShort.AI.Providers.QwenNative`
# if/when the Qwen fallback path is triggered.
config :long_or_short, :morning_brief_provider, LongOrShort.AI.Providers.Claude

# Pre-Trade Briefing provider (LON-172). Same shape contract as
# `:morning_brief_provider` — module must export `call_with_search/2`
# returning `{:ok, %{text, citations, usage, search_calls}}`. Kept as
# a separate config key (not aliased to morning_brief) so each surface
# can be flipped independently when LON-148-style fallback rollouts
# happen per-surface.
config :long_or_short, :research_briefing_provider, LongOrShort.AI.Providers.Claude

# Filing-extraction model map (LON-113).
#
# Two-level mapping: provider module → tier atom → concrete model ID.
#
# `LongOrShort.Filings.Extractor.Router` — an AI-model dispatch helper,
# **unrelated to `Phoenix.Router` / HTTP routing** — picks a tier
# (`:cheap` / `:complex`) per filing type. The tier is intentionally
# provider-agnostic ("how strong does this call need to be?"), so
# adding a new provider (e.g. Qwen via LON-104) is just one extra
# entry below — no code change in the Router or Extractor.
#
# Example future shape:
#
#     LongOrShort.AI.Providers.Qwen => %{
#       cheap: "qwen-turbo",
#       complex: "qwen-plus"
#     }
config :long_or_short, :filing_extraction_models, %{
  LongOrShort.AI.Providers.Claude => %{
    cheap: "claude-haiku-4-5-20251001",
    complex: "claude-sonnet-4-6"
  },
  # LON-104: placeholder entry so the Router doesn't `Map.fetch!`-raise
  # when `:ai_provider` is swapped to Qwen at the AI facade. Both
  # tiers point at `qwen3-max` for now — separating cheap/complex
  # against a smaller Qwen model is a follow-up evaluation; filing
  # extraction via Qwen has not been quality-checked yet.
  LongOrShort.AI.Providers.Qwen => %{
    cheap: "qwen3-max",
    complex: "qwen3-max"
  }
}

# Model pricing in **cents per million tokens** — integer arithmetic
# throughout the cost path, no floats. Consumed by the Tier 1
# `FilingAnalysisWorker` telemetry (LON-135) to compute per-run and
# daily-running-total cost. Unknown models bypass the cost emit
# (telemetry still fires, just with `cost_cents: 0`).
config :long_or_short, :ai_model_prices, %{
  # Anthropic Claude — public pricing snapshot, cents/M tokens
  "claude-haiku-4-5-20251001" => %{input: 100, output: 500},
  "claude-sonnet-4-6" => %{input: 300, output: 1500},
  # Alibaba Qwen Singapore free tier — billed via free quota; placeholder
  # 0 until the tier exhausts and we need a real USD rate.
  "qwen3-max" => %{input: 0, output: 0},
  # Mock provider for tests — mirrors Haiku/Sonnet so cost telemetry
  # assertions are not provider-specific.
  "mock-cheap" => %{input: 100, output: 500},
  "mock-complex" => %{input: 300, output: 1500}
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
