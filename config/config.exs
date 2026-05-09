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

# Filings ingestion (LON-106 epic, Stage 1)
# Children of LongOrShort.Filings.SourceSupervisor. Defaults to []
# until LON-112 wires the DB sink (`Filings.ingest_filing/1`).
config :long_or_short, :enabled_filing_sources, []

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

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
