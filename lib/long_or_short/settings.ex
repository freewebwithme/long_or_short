defmodule LongOrShort.Settings do
  @moduledoc """
  Settings domain -- admin-tunable application configuration backed
  by a `settings` DB table and surfaced via `ash_admin`. LON-125.

  ## What this domain is for

  Some app knobs deserve runtime adjustment without redeploying or
  `iex`-poking the server (per LON-124's epic spec): SeverityRules
  thresholds, window-day durations, batch sizes etc. -- the kind of
  values a trader wants to tune as calibration data comes in.

  This domain stores those values in a `settings` row and exposes
  `ash_admin` CRUD at `/admin` for the `:admin` role. At app boot,
  `LongOrShort.Settings.Loader` reads every row and writes it into
  the `:long_or_short` `Application` env -- so the rest of the
  codebase keeps using the same `Application.get_env/2` reads it
  always has, just now backed by something the admin can change.

  ## What this domain is NOT for

    * **Secrets / API keys** -- `ANTHROPIC_API_KEY`, `QWEN_API_KEY`,
      etc. stay env-only. Storing secrets in DB + admin UI is the
      wrong default; platform secrets (Fly.io / Render env) handle
      it correctly.
    * **Per-user preferences** -- `Accounts.TradingProfile` already
      covers that. This resource is system-wide.
    * **Operational config that needs supervisor restart** -- cron
      schedules, batch sizes touched by long-running workers. Defer
      to LON-124 Stage 6 once the foundation here is in use.

  ## Read path

  Two equivalent ways to read a setting at runtime:

      Application.get_env(:long_or_short, :dilution_profile_window_days, 180)
      LongOrShort.Settings.get(:dilution_profile_window_days, 180)

  Phase 1 -- the latter is a thin wrapper. We keep it around for
  forward compatibility: future stages may layer audit logging,
  cache invalidation, or change-broadcast on top of writes, and
  centralizing the read surface makes that easier to evolve.

  When migrating existing call sites away from module attributes
  or `config.exs` defaults, prefer `Settings.get/2` so the
  intention ("this is a tunable setting, not a build-time
  constant") shows up in grep.

  Naming follows the `Map.fetch/2` + `Map.get/3` idiom -- `fetch/1`
  returns `{:ok, value} | :error`, `get/2` returns the value or a
  default.

  ## Write path

  Admin UI at `/admin/settings` is the canonical write surface.
  Code interfaces (`create_setting`, `update_setting`, etc.) are
  available for seed scripts and tests but are not the recommended
  workflow.

  Changes do NOT propagate to the running app until the next boot
  -- the Loader runs at `Application.start/2`, not on every write.
  This is intentional (Phase 1 scope). Pipelines / supervisors
  that depend on a changed setting need an explicit restart.
  """

  use Ash.Domain, otp_app: :long_or_short, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource LongOrShort.Settings.Setting do
      define :create_setting, action: :create
      define :update_setting, action: :update
      define :destroy_setting, action: :destroy
      define :list_settings, action: :read
      define :get_setting_by_key, action: :by_key, args: [:key], get?: true, not_found_error?: false
    end
  end

  @doc """
  Fetch a setting from the live `Application` env.

  Returns `{:ok, value}` when set, `:error` otherwise. Equivalent
  to `Application.fetch_env(:long_or_short, key)` -- kept here for
  forward compatibility (see moduledoc).

  Pass an atom; this is the canonical key form the Loader uses
  when calling `Application.put_env/3`.
  """
  @spec fetch(atom()) :: {:ok, term()} | :error
  def fetch(key) when is_atom(key) do
    Application.fetch_env(:long_or_short, key)
  end

  @doc """
  Read a setting with an explicit default.

  Equivalent to `Application.get_env(:long_or_short, key, default)`
  -- kept here for forward compatibility (see moduledoc). Prefer
  this form when migrating module-attribute defaults to the
  Settings layer -- the second arg documents the fallback right at
  the call site:

      # Before
      @window_days 180
      ...
      window = Application.get_env(:long_or_short, :dilution_profile_window_days, 180)

      # After
      window = LongOrShort.Settings.get(:dilution_profile_window_days, 180)
  """
  @spec get(atom(), term()) :: term()
  def get(key, default) when is_atom(key) do
    Application.get_env(:long_or_short, key, default)
  end
end
