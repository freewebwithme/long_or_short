import Config
config :long_or_short, Oban, testing: :manual
config :long_or_short, token_signing_secret: "1GkmNKz47nYgYGgQ8YJHvwZ7YCR9J+Vh"
config :bcrypt_elixir, log_rounds: 1
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :long_or_short, LongOrShort.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "long_or_short_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :long_or_short, LongOrShortWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "njBQGiW+WaNOXVxj3Eshssx2Z+lApkcQqHiZAF0Kgopz9soN2rzIzDkhG32FaJjk",
  server: false

# In test we don't send emails
config :long_or_short, LongOrShort.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :long_or_short,
  news_dedup_cleanup_interval: 60_000

# Tests start news sources explicitly via start_supervised! when needed.
config :long_or_short, enabled_news_sources: []

# Tests use a mock provider — never hit the real Anthropic API
config :long_or_short, :ai_provider, LongOrShort.AI.MockProvider

# Route Claude provider HTTP traffic through Req.Test in tests.
config :long_or_short, LongOrShort.AI.Providers.Claude,
  req_plug: {Req.Test, LongOrShort.AI.Providers.Claude}

# CIK mapping sync hits the SEC API + DB on boot. Skip in tests —
# it doesn't play well with the Ecto SQL sandbox.
config :long_or_short, :sync_cik_on_boot, false

config :long_or_short, :watchlist_override, ~w(AAPL TSLA)

config :long_or_short, :enable_price_stream, false
