# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ex_cldr, default_backend: LongOrShort.Cldr
config :ash_oban, pro?: false

config :long_or_short, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [default: 10],
  repo: LongOrShort.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # Daily at 04:00 UTC — SEC mapping refresh (large, run first)
       {"0 4 * * *", LongOrShort.Sec.CikSyncWorker},
       # Daily at 05:00 UTC (~1am EST) — well after US market close.
       {"0 5 * * *", LongOrShort.Tickers.Workers.FinnhubProfileSync}
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
    LongOrShort.Filings
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
config :long_or_short, :filings_ingest_fun, &LongOrShort.Filings.ingest_filing/1

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

# AI provider — defaults to Claude in dev/prod, overridden in test
config :long_or_short, :ai_provider, LongOrShort.AI.Providers.Claude

config :long_or_short, LongOrShort.AI.Providers.Claude,
  model: "claude-sonnet-4-6",
  max_tokens: 4096,
  base_url: "https://api.anthropic.com",
  anthropic_version: "2023-06-01"

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
  }
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
